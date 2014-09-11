use strict;
use warnings;
use Test::More;
use Mojo::TFTPd;
use Mojo::UserAgent;

plan skip_all => 'HTTP_TEST=1' unless $ENV{HTTP_TEST};

{
  package Mojo::TFTPd::Connection::HTTP;
  use Mojo::Base 'Mojo::TFTPd::Connection';

  sub send_data {
    my $self = shift;
    return 1 if exists $self->{http_buffer} and !length $self->{http_buffer};
    return $self->SUPER::send_data(@_);
  }
}

package main;
my $tftpd = Mojo::TFTPd->new(listen => 'localhost:7000', connection_class => 'Mojo::TFTPd::Connection::HTTP');
my $ua = Mojo::UserAgent->new;
my $c;

$tftpd->on(rrq => sub {
    (my $tftpd, $c) = @_;
    my $file = $c->file;

    if ($file =~ m!^https?://!) {
      my $tx = $ua->build_tx(GET => $file);
      $tx->res->max_message_size(0);

      $c->{http_buffer} = '';
      open my $FH, '<', \$c->{http_buffer} or die $!;
      $c->filehandle($FH);

      Scalar::Util::weaken($c);
      $tx->res->content->unsubscribe('read')->on(read => sub {
        my ($content, $bytes) = @_;
        $c->{http_buffer} .= $bytes;
        $c->send_data;
      });

      # callback is called when all data is fetched
      $ua->start($tx, sub { delete $c->{http_buffer}; });
    }
    else {
      # ...
    }
  }
);

$tftpd->start->ioloop->start;

done_testing;
