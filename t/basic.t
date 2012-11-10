BEGIN { $ENV{CHECK_INACTIVE_INTERVAL} = 0.001 }
use strict;
use warnings;
use Test::More;
use Mojo::TFTPd;

my $tftpd = Mojo::TFTPd->new;
my @error;
our $DATA;

$tftpd->on(error => sub { shift; push @error, [@_] });

{
    is Mojo::TFTPd::OPCODE_RRQ, 1, 'OPCODE_RRQ';
    is Mojo::TFTPd::OPCODE_WRQ, 2, 'OPCODE_WRQ';
    is Mojo::TFTPd::OPCODE_DATA, 3, 'OPCODE_DATA';
    is Mojo::TFTPd::OPCODE_ACK, 4, 'OPCODE_ACK';
    is Mojo::TFTPd::OPCODE_ERROR, 5, 'OPCODE_ERROR';
    is Mojo::TFTPd::OPCODE_OACK, 6, 'OPCODE_OACK';
    is $tftpd->ioloop, Mojo::IOLoop->singleton, 'got Mojo::IOLoop';
}

{
    $tftpd->{handle} = bless {}, 'Dummy::Handle';

    $DATA = undef;
    $tftpd->_incoming;
    is $error[0][0], 'Undefined read error.', 'Got read error';

    $DATA = pack 'n', Mojo::TFTPd::OPCODE_ACK;
    $tftpd->_incoming;
    is $error[1][0], 'Connection is missing.', $error[1][0];

    $DATA = pack('n', Mojo::TFTPd::OPCODE_RRQ) . join "\0", "rrq.bin";
    $tftpd->_incoming;
    is $error[2][0], 'Connection is missing.', $error[1][0];

    @error = ();
}

{
    $tftpd->on(rrq => sub {
        my($tftpd, $c) = @_;
        open my $FH, '<', 't/data/' .$c->file;
        $c->filehandle($FH);
    });
}

done_testing;

package Dummy::Handle;
sub sysread { $_[1] = $main::DATA }
sub peername { 'whatever' }
sub peerport { 12345 }
1;
