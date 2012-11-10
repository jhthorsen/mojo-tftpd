package Mojo::TFTPd;

=head1 NAME

Mojo::TFTPd - TFTP server using Mojo::IOLoop

=head1 VERSION

0.01

=head1 SYNOPSIS

    use Mojo::TFTPd;
    my $tftpd = Mojo::TFTPd->new;

    $tftpd->on(rrq => sub {
        my($tftpd, $c) = @_;
        open my $FH, '<', $c->file;
        $c->filehandle($FH);
    });

    $tftpd->start;

=head1 DESCRIPTION

=cut

use Mojo::Base 'Mojolicious::EventEmitter';
use Mojo::IOLoop;
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
    $self->on(error => sub {
        my($self, $str, $connection, $code) = @_;
    });

=head2 rrq

    $self->on(rrq => sub {
        my($self, $connection) = @_;
    });

=head2 wrq

    $self->on(wrq => sub {
        my($self, $connection) = @_;
    });

=head2 ATTRIBUTES

=head2 ioloop

Holds an instance of L<Mojo::IOLoop>.

=cut

has ioloop => sub { Mojo::IOLoop->singleton };

=head2 listen

    $str = $self->server;
    $self->server("127.0.0.1:69");
    $self->server("tftp://*:69");

=cut

has listen => 'tftp://*:69';

=head2 max_connections

How many concurrent connections this server can handle. Default to 1000.

=cut

has max_connections => 1000;

=head2 retries

How many times the server should try to send ACK or DATA to the client.

=cut

has retries => 2;

=head2 inactive_timeout

How long a connection can stay idle.

=cut

has inactive_timeout => 15;

=head1 METHODS

=head2 start

Sets up the server asynchronously. Watch for L</error> to see if everything is
ok.

=cut

sub start {
    my $self = shift;

    $self->{connections} and return;
    $self->{connections} = {};
    $self->ioloop->timer(0 => sub { $self->_start });
}

sub _start {
    my $self = shift;
    my $reactor = $self->ioloop->reactor;
    my $url = $self->server;
    my $handle;

    Scalar::Util::weaken($self);

    if($url =~ /^sftp/) {
        $url = Mojo::URL->new($url);
    }
    else {
        $url = Mojo::URL->new("sftp://$url");
    }

    $handle = IO::Socket::INET->new(
                  LocalAddr => $url->host eq '*' ? '0.0.0.0' : $url->host,
                  LocalPort => $url->port,
                  Proto => 'udp',
              ) or die "Can't create listen socket: $!";

    $self->{handle} = $handle;
    $handle->blocking(0);
    $reactor->io($handle, sub { $self->_incoming });
    $reactor->watch($transport->socket, 1, 0); # watch read events

    $self->ioloop->recurring(CHECK_INACTIVE_INTERVAL, sub {
        my $time = time;
        for my $c (values %{ $self->{connections } }) {
            $self->_delete_connection($c) if $c->[0] < $time;
        }
    });
}

sub _incoming {
    my $self = shift;
    my $handle = $self->{handle}
    my $read = $handle->sysread(my $datagram, DATAGRAM_LENGTH, 0);
    my($opcode, $id, $connection);

    if(!defined $read) {
        return $self->emit(error => $!);
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
    $id = join '|', $handle->peername, $handle->peerport;
    $connection = $self->{connections}{$id};

    if(!$connection) {
        return $self->emit(error => "Connection is missing!");
    }
    elsif($opcode == OPCODE_ACK) {
        $connection->[1]->receive_ack($datagram)
            or return $self->_delete_connection($connection->[1]);
    }
    elsif($opcode == OPCODE_DATA) {
        $connection->[1]->receive_data($datagram)
            or return $self->_delete_connection($connection->[1]);
    }
    elsif($opcode == OPCODE_ERROR) {
        my($code, $msg) = unpack 'nZ*', $datagram;
        return $self->emit(error => $msg, $connection->[1], $code);
    }
    else {
        return $self->emit(error => "Unknown opcode: $opcode", $connection->[1], 0);
    }

    $connection->[0] = time + $self->inactive_timeout;
}

sub _new_request {
    my($self, $type, $opcode, $datagram) = shift;
    my($file, $mode, @rfc) = split "\0", $datagram;
    my $connection;

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
                        peername => $handle->peername,
                        peerport => $handle->peerport,
                        retries => $self->retries,
                        rfc => \@rfc,
                    );

    $self->{connections}{$connection->_id} = [time + $self->inactive_timeout, $connection ];
    $self->emit($type => $connection);
    return $type eq 'rrq' ? $connection->send_packet : $connection->send_ack;
}

sub _delete_connection {
    my($self, $connection) = @_;
    my $name = join '|', $connection->handle->peername, $connection->handle->peerport;

    delete $self->{connections}{$name};
}

sub DEMOLISH {
    my $self = shift;
    my $reactor = eval { $self->ioloop->reactor } or return; # may be undef during global destruction
    my $handle = $self->{handle} or return;

    $reactor->remove($handle);
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;