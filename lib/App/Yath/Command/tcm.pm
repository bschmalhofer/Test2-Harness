package App::Yath::Command::tcm;
use strict;
use warnings;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub show_bench { 0 }

sub run {
    my $self = shift;

    my $args = $self->{+ARGS};
    my $file = shift @$args;

    require $file;

    require Test::Class::Moose::Runner;
    Test::Class::Moose::Runner->import;

    Test::Class::Moose::Runner->new->runtests;

    return 0;
}

1;