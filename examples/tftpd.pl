#!/usr/bin/env perl
use Mojo::Base -strict;
use Mojo::TFTPd;

my $tftpd = Mojo::TFTPd->new(listen => 'tftp://*:12345');

$tftpd->on(error => sub {
    warn "Mojo::TFTPd: ", $_[1], "\n";
});

$tftpd->on(rrq => sub {
    my($tftpd, $connection) = @_;
    warn "rrq: ", $connection->file, "\n";
    open my $FH, '<', $connection->file or return;
    $connection->filehandle($FH);
});

$tftpd->start->ioloop->start;
