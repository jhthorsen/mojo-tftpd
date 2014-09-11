use Mojo::Base -strict;
use Mojo::TFTPd;
use Mojo::UserAgent;

{
  package Mojo::TFTPd::Connection::HTTP;
  use Mojo::Base 'Mojo::TFTPd::Connection';

  sub receive_ack {
    my $self = shift;
    $self->{can_push_data} = 1;
    $self->SUPER::receive_ack(@_);
  }

  sub send_data {
    my $self = shift;

    return 1 if exists $self->{http_buffer} and !length $self->{http_buffer};
    return $self->SUPER::send_data(@_);
  }
}

package main;
my $tftpd = Mojo::TFTPd->new(listen => 'localhost:7000', connection_class => 'Mojo::TFTPd::Connection::HTTP');
my $ua = Mojo::UserAgent->new;

$tftpd->on(rrq => sub {
    my ($tftpd, $c) = @_;
    my $file = $c->file;

    if ($file =~ m!^https?://!) {
      my $tx = $ua->build_tx(GET => $file);
      $tx->res->max_message_size(0);

      $c->{http_buffer} = '';
      $c->{can_push_data} = 1;
      open my $FH, '<', \$c->{http_buffer} or die $!;
      $c->filehandle($FH);

      Scalar::Util::weaken($c);

      # send the remaining chunk
      $tx->on(finish => sub { $c and $c->send_data; });

      # stream HTTP chunks
      $tx->res->content->unsubscribe('read')->on(read => sub {
        my ($content, $bytes) = @_;
        return unless $c;
        $c->{http_buffer} .= $bytes;
        $c->send_data if delete $c->{can_push_data} and length($c->{http_buffer}) % $c->blocksize;
      });

      # callback is called when all data is fetched
      $ua->start($tx, sub {});
    }
    else {
      # ...
    }
  }
);

$tftpd->start->ioloop->start;
