#!/usr/bin/env perl
use Mojo::Base -strict;
use Mojo::TFTPd;

# MOJO_TFTPD_DEBUG=1 perl -Ilib examples/tftpd.pl

my $tftpd = Mojo::TFTPd->new(listen => 'tftp://*:12345');

$tftpd->on(error => sub {
    warn "Mojo::TFTPd: ", $_[1], "\n";
});

$tftpd->on(rrq => sub {
    my($tftpd, $connection) = @_;
    open my $FH, '<', $connection->file or return;
    $connection->filehandle($FH);
});

$tftpd->on(wrq => sub {
    my($tftpd, $connection) = @_;
    open my $FH, '>', '/dev/null' or return;
    $connection->filehandle($FH);
});

$tftpd->start;
$tftpd->ioloop->start unless $tftpd->ioloop->is_running;