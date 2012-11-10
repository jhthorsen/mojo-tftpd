#!/usr/bin/env perl

use 5.008001;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'Mojo::TFTPd',
    AUTHOR        => 'Jan Henning Thorsen <jhthorsen@cpan.org>',
    LICENSE       => 'perl',
    VERSION_FROM  => 'lib/Mojo/TFTPd.pm',
    ABSTRACT_FROM => 'lib/Mojo/TFTPd.pm',

    BUILD_REQUIRES => {'Test::More' => '0.88'},
    PREREQ_PM      => {
        'Mojolicious'     => '3.0',
    },
    META_MERGE => {
        resources => {
            bugtracker => 'https://github.com/jhthorsen/mojo-tftpd/issues',
            repository => 'http://github.com/jhthorsen/mojo-tftpd',
            license    => 'http://dev.perl.org/licenses/',
        }
    }
);
