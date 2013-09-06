use ExtUtils::MakeMaker;
WriteMakefile(
  NAME => 'Mojo::TFTPd',
  ABSTRACT_FROM => 'lib/Mojo/TFTPd.pm',
  VERSION_FROM => 'lib/Mojo/TFTPd.pm',
  AUTHOR => 'Jan Henning Thorsen <jhthorsen@cpan.org>',
  LICENSE => 'perl',
  PREREQ_PM => {
    'Mojolicious' => '4.30',
  },
  BUILD_REQUIRES => {
    'Test::More' => '0.90',
  },
  META_MERGE => {
    resources => {
      license => 'http://dev.perl.org/licenses/',
      homepage => 'https://metacpan.org/release/Mojo-TFTPd',
      bugtracker => 'http://rt.cpan.org/NoAuth/Bugs.html?Dist=Mojo-TFTPd',
      repository => 'https://github.com/jhthorsen/mojo-tftpd',
    },
  },
  test => {
    TESTS => 't/*.t',
  },
);
