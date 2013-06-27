package Mojo::TFTPd;

=head1 NAME

Mojo::TFTPd - Trivial File Transfer Protocol daemon

=head1 VERSION

0.01

=head1 SYNOPSIS

    use Mojo::TFTPd;
    my $tftpd = Mojo::TFTPd->new;

    $tftpd->on(error => sub {
        warn "TFTPd: $_[1]\n";
    });

    $tftpd->on(rrq => sub {
        my($tftpd, $c) = @_;
        open my $FH, '<', $c->file;
        $c->filehandle($FH);
    });

    $tftpd->on(wrq => sub {
        my($tftpd, $c) = @_;
        open my $FH, '>', '/dev/null';
        $c->filehandle($FH);
    });

    $self->on(finish => sub {
        my($tftpd, $c, $error) = @_;
        warn "Connection: $error\n" if $error;
    });

    $tftpd->start;
    $tftpd->ioloop->start unless $tftpd->ioloop->is_running;

=head1 DESCRIPTION

This module implement a server for the
L<Trivial File Transfer Protocol|http://en.wikipedia.org/wiki/Trivial_File_Transfer_Protocol>.

From Wikipedia:

    Trivial File Transfer Protocol (TFTP) is a file transfer protocol notable
    for its simplicity. It is generally used for automated transfer of
    configuration or boot files between machines in a local environment.

The connection ($c) which is referred to in this document is an instance of
L<Mojo::TFTPd::Connection>.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::TFTPd::Connection;
use constant OPCODE_RRQ => 1;
use constant OPCODE_WRQ => 2;
use constant OPCODE_DATA => 3;
use constant OPCODE_ACK => 4;
use constant OPCODE_ERROR => 5;
use constant OPCODE_OACK => 6;
use constant CHECK_INACTIVE_INTERVAL => $ENV{MOJO_TFTPD_CHECK_INACTIVE_INTERVAL} || 3;
use constant DATAGRAM_LENGTH => $ENV{MOJO_TFTPD_DATAGRAM_LENGTH} || 512;
use constant DEBUG => $ENV{MOJO_TFTPD_DEBUG} ? 1 : 0;

our $VERSION = eval '0.01';

=head1 EVENTS

=head2 error

    $self->on(error => sub {
        my($self, $str) = @_;
    });

This event is emitted when something goes wrong: Fail to L</listen> to socket,
read from socket or other internal errors.

=head2 finish

    $self->on(finish => sub {
        my($self, $c, $error) = @_;
    });

This event is emitted when the client finish, either successfully or due to an
error. C<$error> will be an empty string on success.

=head2 rrq

    $self->on(rrq => sub {
        my($self, $c) = @_;
    });

This event is emitted when a new read request arrives from a client. The
callback should set L<Mojo::TFTPd::Connection/filehandle> or the connection
will be dropped.

=head2 wrq

    $self->on(wrq => sub {
        my($self, $c) = @_;
    });

This event is emitted when a new write request arrives from a client. The
callback should set L<Mojo::TFTPd::Connection/filehandle> or the connection
will be dropped.

=head1 ATTRIBUTES

=head2 ioloop

Holds an instance of L<Mojo::IOLoop>.

=cut

has ioloop => sub { Mojo::IOLoop->singleton };

=head2 listen

    $str = $self->server;
    $self->server("127.0.0.1:69");
    $self->server("tftp://*:69"); # any interface

The bind address for this server.

=cut

has listen => 'tftp://*:69';

=head2 max_connections

How many concurrent connections this server can handle. Default to 1000.

=cut

has max_connections => 1000;

=head2 retries

How many times the server should try to send ACK or DATA to the client before
dropping the L<connection|Mojo::TFTPd::Connection>.

=cut

has retries => 1;

=head2 inactive_timeout

How long a L<connection|Mojo::TFTPd::Connection> can stay idle before

=cut

has inactive_timeout => 15;

=head1 METHODS

=head2 start

Starts listening to the address and port set in L</Listen>. The L</error>
event wille be emitted if the server fail to start.

=cut

sub start {
    my $self = shift;
    my $reactor = $self->ioloop->reactor;
    my $socket;

    $self->{connections} and return $self;
    $self->{connections} = {};

    # split $self->listen into host and port
    my ($host, $port) = $self->_parse_listen;

    warn "[Mojo::TFTPd] Listen to $host:$port\n" if DEBUG;

    $socket = IO::Socket::INET->new(
                  LocalAddr => $host,
                  LocalPort => $port,
                  Proto => 'udp',
              );

    if(!$socket) {
        delete $self->{connections};
        return $self->emit(error => "Can't create listen socket: $!");
    };

    Scalar::Util::weaken($self);

    $socket->blocking(0);
    $reactor->io($socket, sub { $self->_incoming });
    $reactor->watch($socket, 1, 0); # watch read events
    $self->{socket} = $socket;
    $self->{checker}
        = $self->ioloop->recurring(CHECK_INACTIVE_INTERVAL || 3, sub {
            my $timeout = time - $self->inactive_timeout;
            for my $c (values %{ $self->{connections} }) {
                $timeout < $c->{timestamp} and next;
                $c->error('Inactive timeout');
                $self->_delete_connection($c);
            }
        });

    return $self;
}

sub _incoming {
    my $self = shift;
    my $socket = $self->{socket};
    my $read = $socket->recv(my $datagram, DATAGRAM_LENGTH);
    my($opcode, $connection);

    if(!defined $read) {
        return $self->emit(error => "Read: $!");
    }

    $opcode = unpack 'n', substr $datagram, 0, 2, '';

    # new connection
    if($opcode eq OPCODE_RRQ) {
        return $self->_new_request(rrq => $datagram);
    }
    elsif($opcode eq OPCODE_WRQ) {
        return $self->_new_request(wrq => $datagram);
    }

    # existing connection
    $connection = $self->{connections}{$socket->peername};

    if(!$connection) {
        return $self->emit(error => "@{[$socket->peerhost]} has no connection");
    }
    elsif($opcode == OPCODE_ACK) {
        return if $connection->receive_ack($datagram) and $connection->send_data;
    }
    elsif($opcode == OPCODE_DATA) {
        return if $connection->receive_data($datagram) and $connection->send_ack;
    }
    elsif($opcode == OPCODE_ERROR) {
        my($code, $msg) = unpack 'nZ*', $datagram;
        $connection->error("($code) $msg");
    }
    else {
        $connection->error("Unknown opcode");
    }

    # if something goes wrong or finish with connection
    $self->_delete_connection($connection);
}

sub _new_request {
    my($self, $type, $datagram) = @_;
    my($file, $mode, @rfc) = split "\0", $datagram;
    my $socket = $self->{socket};
    my $connection;

    warn "[Mojo::TFTPd] <<< @{[$socket->peerhost]} $type $file $mode @rfc\n" if DEBUG;

    if(!$self->has_subscribers($type)) {
        $self->emit(error => "Cannot handle $type requests");
        return;
    }
    if($self->max_connections <= keys %{ $self->{connections} }) {
        $self->emit(error => "Max connections ($self->{max_connections}) reached");
        return;
    }

    $connection = Mojo::TFTPd::Connection->new(
                        file => $file,
                        mode => $mode,
                        peerhost => $socket->peerhost,
                        peername => $socket->peername,
                        retries => $self->retries,
                        rfc => \@rfc,
                        socket => $socket,
                    );

    $self->emit($type => $connection);

    if($type eq 'rrq' ? $connection->send_data : $connection->send_ack) {
        $self->{connections}{$connection->peername} = $connection;
    }
    else {
        $self->emit(finish => $connection, $connection->error);
    }
}

sub _parse_listen {
    my $self = shift;

    my ($scheme, $host, $port) = $self->listen =~ m!
      (?: ([^:/]+) :// )?   # part before ://
      ([^:]*)               # everyting until a :
      (?: : (\d+) )?        # any digits after the :
    !xms;

    # if scheme is set but no port, use scheme
    $port = getservbyname($scheme, '') if $scheme && !defined $port;

    # use port 69 as fallback
    $port //= 69;

    # if host == '*', replace it with '0.0.0.0'
    $host = '0.0.0.0' if $host eq '*';

    return ($host, $port);
}

sub _delete_connection {
    my($self, $connection) = @_;
    delete $self->{connections}{$connection->peername};
    $self->emit(finish => $connection, $connection->error);
}

sub DEMOLISH {
    my $self = shift;
    my $reactor = eval { $self->ioloop->reactor } or return; # may be undef during global destruction

    $reactor->remove($self->{checker}) if $self->{checker};
    $reactor->remove($self->{socket}) if $self->{socket};
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
