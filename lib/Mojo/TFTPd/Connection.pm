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

=head2 file

The filename the client requested to read or write.

=head2 filehandle

This must be set inside the L<rrq|Mojo::TFTPd/rrq> or L<rrw|Mojo::TFTPd/rrw>
event or the connection will be dropped.

=head2 mode

Either "ascii", "octet" or empty string if unknown.

=head2 opcode

1 (rrq), 2 (wrq) or 0 if unknown.

=head2 packet_number

=head2 retries

Number of times L</send_data> or L</send_ack> can be retried before the
connection is dropped. This value comes from L<Mojo::TFTPd/retries>.

=head2 rfc

Contains extra parameters the client has provided. These parameters are stored
in an array ref.

=cut

has file => '/dev/null';
has filehandle => undef;
has mode => '';
has opcode => 0;
has packet_number => 1;
has peername => '';
has retries => 2;
has rfc => sub { [] };

=head1 METHODS

=head2 receive_ack

=cut

sub receive_ack {
    my $self = shift;
    my($n) = unpack 'n', shift;

    return ++$self->{packet_number} if $n == $self->packet_number;
    return $self->{retries}--;
}

=head2 receive_data

=cut

sub receive_data {
    my $self = shift;
}

=head2 send_ack

=cut

sub send_ack {
    my $self = shift;
}

=head2 send_data

=cut

sub send_data {
    my $self = shift;
    my $FH = $self->filehandle;
    my $n = $self->packet_number;
    my($data, $sent);

    if(!$FH) {
        $self->send_error('file_not_found');
        return 0;
    }
    elsif(not seek $FH, ($n - 1) * DATAGRAM_LENGTH, 0) {
        warn "[Mojo::TFTPd] seek @{[$self->file]} $!\n" if DEBUG;
        $self->send_error('file_not_found');
        return 0;
    }
    if(not defined read $FH, $data, DATAGRAM_LENGTH) {
        warn "[Mojo::TFTPd] read @{[$self->file]} $!\n" if DEBUG;
        $self->send_error('file_not_found');
        return 0;
    }
    if(0 == length $data and 1 < $self->packet_number) {
        warn "[Mojo::TFTPd] sent @{[$self->file]}\n" if DEBUG;
        return -1;
    }

    $sent = $self->{handle}->send(
                pack('nna*', OPCODE_DATA, $self->packet_number, $data),
                MSG_DONTWAIT,
                $self->peername,
            );

    if(!$sent) {
        warn "[Mojo::TFTPd] send @{[$self->file]} $!\n" if DEBUG;
        $self->{retries}--;
        return 0;
    }

    return length $data < DATAGRAM_LENGTH ? 2 : 1;
}

=head2 send_error

=cut

sub send_error {
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;