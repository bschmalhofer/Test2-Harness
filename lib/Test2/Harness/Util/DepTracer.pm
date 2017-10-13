package Test2::Harness::Util::DepTracer;
use strict;
use warnings;

our $VERSION = '0.001022';

use Test2::Harness::Util::HashBase qw/
    -_on
    -exclude
    -dep_map
    -loaded
    -my_require
    -real_require
/;

my %DEFAULT_EXCLUDE = (
    'warnings.pm' => 1,
    'strict.pm'   => 1,
);

sub start { shift->{+_ON} = 1 }
sub stop  { shift->{+_ON} = 0 }

sub clear_loaded { %{$_[0]->{+LOADED}} = () }

my %REQUIRE_CACHE;

sub init {
    my $self = shift;

    my $exclude = $self->{+EXCLUDE} ||= { %DEFAULT_EXCLUDE };

    my $stash = \%CORE::GLOBAL::;
    # We use a string in the reference below to prevent the glob slot from
    # being auto-vivified by the compiler.
    $self->{+REAL_REQUIRE} = exists $stash->{require} ? \&{'CORE::GLOBAL::require'} : undef;

    my $dep_map = $self->{+DEP_MAP} ||= {};
    my $loaded  = $self->{+LOADED} ||= {};

    my %seen;

    my $require = $self->{+MY_REQUIRE} = sub {
        my ($file) = @_;

        my $loaded_by = $self->loaded_by;

        my $real_require = $self->{+REAL_REQUIRE};
        unless($real_require) {
            my $caller = $loaded_by->[0];
            $real_require = $REQUIRE_CACHE{$caller} ||= eval "package $caller; sub { CORE::require(\$_[0]) }" or die $@;
        }

        goto &$real_require unless $self->{+_ON};

        if ($file =~ m/^[_a-z]/i) {
            unless ($exclude->{$file}) {
                push @{$dep_map->{$file}} => $loaded_by;
                $loaded->{$file}++;
            }
        }

        goto &$real_require;
    };

    {
        no strict 'refs';
        no warnings 'redefine';
        *{'CORE::GLOBAL::require'} = $require;
    }
}

sub loaded_by {
    my $level = 1;

    while(my @caller = caller($level++)) {
        next if $caller[0] eq __PACKAGE__;

        return [$caller[0], $caller[1]];
    }

    return ['', ''];
}

1;
