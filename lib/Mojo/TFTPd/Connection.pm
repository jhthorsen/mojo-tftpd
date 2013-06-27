package Mojo::TFTPd::Connection;

=head1 NAME

Mojo::TFTPd::Connection - A connection class for Mojo::TFTPd

=head1 SYNOPSIS

See L<Mojo::TFTPd>

=cut

use Mojo::Base -base;
use Socket;
use constant OPCODE_DATA => 3;
use constant OPCODE_ACK => 4;
use constant OPCODE_ERROR => 5;
use constant DEBUG => $ENV{MOJO_TFTPD_DEBUG} ? 1 : 0;

our %ERROR_CODES = (
    not_defined => [0, 'Not defined, see error message'],
    unknown_opcode => [0, 'Unknown opcode: %s'],
    no_connection => [0, 'No connection'],
    file_not_found => [1, 'File not found'],
    access_violation => [2, 'Access violation'],
    disk_full => [3, 'Disk full or allocation exceeded'],
    illegal_operation => [4, 'Illegal TFTP operation'],
    unknown_transfer_id => [5, 'Unknown transfer ID'],
    file_exists => [6, 'File already exists'],
    no_such_user => [7, 'No such user'],
);

=head1 ATTRIBUTES

=head2 blocksize

The negotiated blocksize.
Default is 512 Byte.

=head2 error

Useful to check inside L<Mojo::TFTPd/finish> events to see if anything has
gone wrong. Holds a string describing the error.

=head2 file

The filename the client requested to read or write.

=head2 filehandle

This must be set inside the L<rrq|Mojo::TFTPd/rrq> or L<rrw|Mojo::TFTPd/rrw>
event or the connection will be dropped.

=head2 mode

Either "ascii", "octet" or empty string if unknown.

=head2 peerhost

The IP address of the remove client.

=head2 peername

Packet address of the remote client.

=head2 retries

Number of times L</send_data> or L</send_ack> can be retried before the
connection is dropped. This value comes from L<Mojo::TFTPd/retries>.

=head2 socket

The UDP handle to send data to.

=head2 rfc

Contains extra parameters the client has provided. These parameters are stored
in an array ref.

=cut

has blocksize => 512;
has error => '';
has file => '/dev/null';
has filehandle => undef;
has mode => '';
has peerhost => '';
has peername => '';
has retries => 2;
has rfc => sub { [] };
has socket => undef;
has _sequence_number => 1;

=head1 METHODS

=head2 send_data

This method is called when the server sends DATA to the client.

=cut

sub send_data {
    my $self = shift;
    my $FH = $self->filehandle;
    my $n = $self->_sequence_number;
    my($data, $sent);

    $self->{timestamp} = time;

    if(!$FH) {
        return $self->send_error(file_not_found => 'No filehandle');
    }
    elsif(not seek $FH, ($n - 1) * $self->blocksize, 0) {
        return $self->send_error(file_not_found => "Seek: $!");
    }
    if(not defined read $FH, $data, $self->blocksize) {
        return $self->send_error(file_not_found => "Read: $!");
    }
    if(length $data < $self->blocksize) {
        $self->{_last_sequence_number} = $n;
    }

    warn "[Mojo::TFTPd] >>> $self->{peerhost} data $n (@{[length $data]})\n" if DEBUG;

    $sent = $self->socket->send(
                pack('nna*', OPCODE_DATA, $n, $data),
                MSG_DONTWAIT,
                $self->peername,
            );

    return 0 unless length $data;
    return 1 if $sent;
    $self->error("Send: $!");
    return $self->{retries}--;
}

=head2 receive_ack

This method is called when the client sends ACK to the server.

=cut

sub receive_ack {
    my $self = shift;
    my($n) = unpack 'n', shift;

    warn "[Mojo::TFTPd] <<< $self->{peerhost} ack $n\n" if DEBUG;

    return 0 if $self->{_last_sequence_number} and $n == $self->{_last_sequence_number};
    return ++$self->{_sequence_number} if $n == $self->{_sequence_number};
    $self->error('Invalid packet number');
    return $self->{retries}--;
}

=head2 receive_data

This method is called when the client sends DATA to the server.

=cut

sub receive_data {
    my $self = shift;
    my($n, $data) = unpack 'na*', shift;
    my $FH = $self->filehandle;

    warn "[Mojo::TFTPd] <<< $self->{peerhost} data $n (@{[length $data]})\n" if DEBUG;

    unless($FH) {
        return $self->send_error(illegal_operation => 'No filehandle');
    }
    unless($n == $self->_sequence_number) {
        $self->error('Invalid packet number');
        return $self->{retries}--;
    }
    unless(print $FH $data) {
        return $self->send_error(illegal_operation => "Write: $!");
    };
    unless(length $data == $self->blocksize) {
        $self->{_last_sequence_number} = $n;
    }

    $self->{_sequence_number}++;
    return 1;
}

=head2 send_ack

This method is called when the server sends ACK to the client.

=cut

sub send_ack {
    my $self = shift;
    my $n = $self->_sequence_number - 1;
    my $sent;

    $self->{timestamp} = time;
    warn "[Mojo::TFTPd] >>> $self->{peerhost} ack $n\n" if DEBUG;

    $sent = $self->socket->send(
                pack('nn', OPCODE_ACK, $n),
                MSG_DONTWAIT,
                $self->peername,
            );

    return 0 if defined $self->{_last_sequence_number};
    return 1 if $sent;
    $self->error("Send: $!");
    return $self->{retries}--;
}

=head2 send_error

Used to report error to the client.

=cut

sub send_error {
    my($self, $name) = @_;
    my $err = $ERROR_CODES{$name} || $ERROR_CODES{not_defined};

    warn "[Mojo::TFTPd] >>> $self->{peerhost} error @$err\n" if DEBUG;

    $self->error($_[2]);
    $self->socket->send(
        pack('nnZ*', OPCODE_ERROR, @$err),
        MSG_DONTWAIT,
        $self->peername,
    );

    return 0;
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
