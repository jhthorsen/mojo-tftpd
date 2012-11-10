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
use Mojo::URL;
use constant OPCODE_RRQ => 1;
use constant OPCODE_WRQ => 2;
use constant OPCODE_DATA => 3;
use constant OPCODE_ACK => 4;
use constant OPCODE_ERROR => 5;
use constant OPCODE_OACK => 6;
use constant CHECK_INACTIVE_INTERVAL => 5;
use constant DATAGRAM_LENGTH => $ENV{MOJO_TFTPD_DATAGRAM_LENGTH} || 512;
use constant DEBUG => $ENV{MOJO_TFTPD_DEBUG} ? 1 : 0;

our $VERSION = '0.01';

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

has retries => 2;

=head2 inactive_timeout

How long a L<connection|Mojo::TFTPd::Connection> can stay idle before

=cut

has inactive_timeout => 15;

=head1 METHODS

=head2 start

Sets up the server asynchronously. The L</error> event wille be fired unless
this server could start.

=cut

sub start {
    my $self = shift;
    my $reactor = $self->ioloop->reactor;
    my $url = $self->listen;
    my $socket;

    $self->{connections} and return $self;
    $self->{connections} = {};

    if($url =~ /^tftp/) {
        $url = Mojo::URL->new($url);
    }
    else {
        $url = Mojo::URL->new("tftp://$url");
    }

    warn "[Mojo::TFTPd] Listen to $url\n" if DEBUG;

    $socket = IO::Socket::INET->new(
                  LocalAddr => $url->host eq '*' ? '0.0.0.0' : $url->host,
                  LocalPort => $url->port,
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
        = $self->ioloop->recurring(CHECK_INACTIVE_INTERVAL, sub {
            my $time = time - $self->inactive_timeout;
            for my $c (values %{ $self->{connections} }) {
                $self->_delete_connection($c) if $c->{timestamp} < $time;
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
        return $self->_new_request(rrq => $opcode, $datagram);
    }
    elsif($opcode eq OPCODE_WRQ) {
        return $self->_new_request(wrq => $opcode, $datagram);
    }

    # existing connection
    $connection = $self->{connections}{$socket->peername};

    if(!$connection) {
        $self->emit(error => "@{[$socket->peerhost]} has no connection.");
    }
    elsif($opcode == OPCODE_ACK) {
        $connection->receive_ack($datagram)
            or return $self->_delete_connection($connection);
        $connection->send_data;
    }
    elsif($opcode == OPCODE_DATA) {
        $connection->receive_data($datagram)
            or return $self->_delete_connection($connection);
        $connection->send_ack;
    }
    elsif($opcode == OPCODE_ERROR) {
        my($code, $msg) = unpack 'nZ*', $datagram;
        $connection->error("($code) $msg");
        $self->_delete_connection($connection);
    }
    else {
        $connection->error("Unknown opcode");
        $self->_delete_connection($connection);
    }
}

sub _new_request {
    my($self, $type, $opcode, $datagram) = @_;
    my($file, $mode, @rfc) = split "\0", $datagram;
    my $socket = $self->{socket};
    my $connection;

    warn "[Mojo::TFTPd] <<< @{[$socket->peerhost]} $type $file $mode @rfc\n" if DEBUG;

    if(!$self->has_subscribers($type)) {
        $self->emit(error => "Cannot handle $type requests");
        return;
    }
    if($self->max_connections < keys %{ $self->{connections} }) {
        $self->emit(error => "Max connections reached");
        return;
    }

    $connection = Mojo::TFTPd::Connection->new(
                        file => $file,
                        mode => $mode,
                        opcode => $opcode,
                        socket => $socket,
                        peername => $socket->peername,
                        peerhost => $socket->peerhost,
                        retries => $self->retries,
                        rfc => \@rfc,
                    );

    $self->{connections}{$connection->peername} = $connection;
    $self->emit($type => $connection);
    return $type eq 'rrq' ? $connection->send_data : $connection->send_ack;
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