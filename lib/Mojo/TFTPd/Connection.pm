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
use constant DATAGRAM_LENGTH => $ENV{MOJO_TFTPD_DATAGRAM_LENGTH} || 512;
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

=head2 retries

Number of times L</send_data> or L</send_ack> can be retried before the
connection is dropped. This value comes from L<Mojo::TFTPd/retries>.

=head2 socket

The UDP handle to send data to.

=head2 rfc

Contains extra parameters the client has provided. These parameters are stored
in an array ref.

=cut

has error => '';
has file => '/dev/null';
has filehandle => undef;
has mode => '';
has opcode => 0;
has peername => '';
has retries => 2;
has socket => undef;
has rfc => sub { [] };
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
    elsif(not seek $FH, ($n - 1) * DATAGRAM_LENGTH, 0) {
        return $self->send_error(file_not_found => "Seek: $!");
    }
    if(not defined read $FH, $data, DATAGRAM_LENGTH) {
        return $self->send_error(file_not_found => "Read: $!");
    }
    if(0 == length $data and 1 < $n) {
        return 1;
    }

    warn "[Mojo::TFTPd] >>> $self->{peerhost} data $n\n" if DEBUG;

    $sent = $self->socket->send(
                pack('nna*', OPCODE_DATA, $n, $data),
                MSG_DONTWAIT,
                $self->peername,
            );

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

    return ++$self->{_sequence_number} if $n == $self->_sequence_number;
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

    warn "[Mojo::TFTPd] <<< $self->{peerhost} data $n\n" if DEBUG;

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

    $self->error($_[1]);
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