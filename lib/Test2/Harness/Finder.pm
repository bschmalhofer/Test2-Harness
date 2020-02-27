package Test2::Harness::Finder;
use strict;
use warnings;

our $VERSION = '0.999009';

use Test2::Harness::Util qw/clean_path/;
use List::Util qw/first/;
use Cwd qw/getcwd/;

use Test2::Harness::TestFile;
use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <default_search <default_at_search

    <durations <maybe_durations +duration_data

    <exclude_files  <exclude_patterns

    <no_long <only_long

    <search <extensions

    <multi_project
};

sub munge_settings {}

sub init {
    my $self = shift;

    $self->{+EXCLUDE_FILES} = { map {( $_ => 1 )} @{$self->{+EXCLUDE_FILES}} } if ref($self->{+EXCLUDE_FILES}) eq 'ARRAY';
}

sub duration_data {
    my $self = shift;
    return $self->{+DURATION_DATA} //= $self->pull_durations() // {};
}

sub pull_durations {
    my $self = shift;

    my $primary  = delete $self->{+MAYBE_DURATIONS} || [];
    my $fallback = delete $self->{+DURATIONS};

    for my $path (@$primary) {
        local $@;
        my $durations = eval { $self->_pull_durations($path) } or print "Could not fetch optional durations '$path', ignoring...\n";
        next unless $durations;

        print "Found durations: $path\n";
        return $self->{+DURATION_DATA} = $durations;
    }

    return $self->{+DURATION_DATA} = $self->_pull_durations($fallback)
        if $fallback;
}

sub _pull_durations {
    my $self = shift;
    my ($in) = @_;

    if (my $type = ref($in)) {
        return $self->{+DURATIONS} = $in if $type eq 'HASH';
    }
    elsif ($in =~ m{^https?://}) {
        require HTTP::Tiny;
        my $ht = HTTP::Tiny->new();
        my $res = $ht->get($in, {headers => {'Content-Type' => 'application/json'}});

        die "Could not query durations from '$in'\n$res->{status}: $res->{reason}\n$res->{content}"
            unless $res->{success};

        return $self->{+DURATIONS} = decode_json($res->{content});
    }
    elsif(-f $in) {
        require Test2::Harness::Util::File::JSON;
        my $file = Test2::Harness::Util::File::JSON->new(name => $in);
        return $self->{+DURATIONS} = $file->read();
    }

    die "Invalid duration specification: $in";
}

sub find_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    return $self->find_multi_project_files($plugins, $settings) if $self->multi_project;
    return $self->find_project_files($plugins, $settings, $self->search);
}

sub find_multi_project_files {
    my $self = shift;
    my ($plugins, $settings) = @_;

    my $search = $self->search // [];

    die "multi-project search must be a single directory, or the current directory" if @$search > 1;
    my ($pdir) = @$search;
    my $dir = clean_path(getcwd());

    my $out = [];
    my $ok = eval {
        chdir($pdir) if defined $pdir;
        my $ret = clean_path(getcwd());

        opendir(my $dh, '.') or die "Could not open project dir: $!";
        for my $subdir (readdir($dh)) {
            chdir($ret);

            next if $subdir =~ m/^\./;
            my $path = clean_path(File::Spec->catdir($ret, $subdir));
            next unless -d $path;

            chdir($path) or die "Could not chdir to $path: $!\n";

            for my $item (@{$self->find_project_files($plugins, $settings, [])}) {
                push @{$item->queue_args} => ('ch_dir' => $path);
                push @$out => $item;
            }
        }

        chdir($ret);
        1;
    };
    my $err = $@;

    chdir($dir);
    die $err unless $ok;

    return $out;
}

sub find_project_files {
    my $self = shift;
    my ($plugins, $settings, $input) = @_;

    $input   //= [];
    $plugins //= [];

    my $default_search = [@{$self->default_search}];
    push @$default_search => @{$self->default_at_search} if $settings->check_prefix('run') && $settings->run->author_testing;

    $_->munge_search($input, $default_search, $settings) for @$plugins;

    my $search = @$input ? $input : $default_search;

    die "No tests to run, search is empty\n" unless @$search;

    my $durations = $self->duration_data;

    my (%seen, @tests, @dirs);
    for my $path (@$search) {
        push @dirs => $path and next if -d $path;

        unless(-f $path) {
            die "'$path' is not a valid file or directory.\n" if @$input;
            next;
        }

        $path = clean_path($path, 0);
        $seen{$path}++;

        my $test;
        unless (first { $test = $_->claim_file($path, $settings) } @$plugins) {
            $test = Test2::Harness::TestFile->new(file => $path);
        }

        my $rel = $test->relative;
        $test->set_duration($durations->{$rel}) if $durations->{$rel};
        if (my @exclude = $self->exclude_file($test)) {
            if (@$input) {
                print STDERR "File '$path' was listed on the command line, but has been exluded for the following reasons:\n";
                print STDERR "  $_\n" for @exclude;
            }

            next;
        }

        push @tests => $test;
    }

    if (@dirs) {
        require File::Find;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    no warnings 'once';

                    my $file = clean_path($File::Find::name, 0);

                    return if $seen{$file}++;
                    return unless -f $file;

                    my $test;
                    unless(first { $test = $_->claim_file($file, $settings) } @$plugins) {
                        for my $ext (@{$self->extensions}) {
                            next unless m/\.\Q$ext\E$/;
                            $test = Test2::Harness::TestFile->new(file => $file);
                            last;
                        }
                    }

                    return unless $test;
                    my $rel = $test->relative;
                    $test->set_duration($durations->{$rel}) if $durations->{$rel};
                    return unless $self->include_file($test);
                    push @tests => $test;
                },
            },
            @dirs
        );
    }

    $_->munge_files(\@tests, $settings) for @$plugins;

    return [ sort { $a->rank <=> $b->rank || $a->file cmp $b->file } @tests ];
}

sub include_file {
    my $self = shift;
    my ($test) = @_;

    my @exclude = $self->exclude_file($test);

    return !@exclude;
}

sub exclude_file {
    my $self = shift;
    my ($test) = @_;

    my @out;

    push @out => "File has a do-not-run directive inside it." unless $test->check_feature(run => 1);

    my $full = $test->file;
    my $rel  = $test->relative;

    push @out => 'File is in the exclude list.' if $self->exclude_files->{$full} || $self->exclude_files->{$rel};
    push @out => 'File matches an exclusion pattern.' if first { $rel =~ m/$_/ } @{$self->exclude_patterns};

    push @out => 'File is marked as "long", but the "no long tests" opition was specified.'
        if $self->no_long && $test->check_duration eq 'long';

    push @out => 'File is not marked "long", but the "only long tests" option was specified.'
        if $self->only_long && $test->check_duration ne 'long';

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Finder - Library that searches for test files

=head1 DESCRIPTION

The finder is responsible for locating test files that should be run. You can
subclass the finder and instruct yath to use your subclass.

=head1 SYNOPSIS

=head2 USING A CUSTOM FINDER

To use Test2::Harness::Finder::MyFinder:

    $ yath test --finder MyFinder

To use Another::Finder

    $ yath test --finder +Another::Finder

By default C<Test2::Harness::Finder::> is prefixed onto your custom finder, use
'+' before the class name or prevent this.

=head2 SUBCLASSING

    use parent 'Test2::Harness::Finder';
    use Test2::Harness::TestFile;

    # Custom finders may provide their own options if desired.
    # This is optional.
    use App::Yath::Options;
    option foo => (
        ...
    );

    # This is the main method to override.
    sub find_project_files {
        my $self = shift;
        my ($plugins, $settings, $search) = @_;

        return [
            Test2::Harness::TestFile->new(...),
            Test2::Harness::TestFile->new(...),
            ...,
        ];
    }

=head1 METHODS

These are important state methods, as well as utility methods for use in your
subclasses.

=over 4

=item $bool = $finder->multi_project

True if the C<yath projects> command was used.

=item $arrayref = $finder->find_files($plugins, $settings)

This is the main method. This method returns an arrayref of
L<Test2::Harness::TestFile> instances, each one representing a single test to
run.

$plugins is a list of plugins, some may be class names, others may be
instances.

$settings is an L<Test2::Harness::Settings> instance.

B<Note:> In many cases it is better to override C<find_project_files()> in your
subclasses.

=item $durations = $finder->duration_data

This will fetch the durations data if ant was provided. This is a hashref of
relative test paths as keys where the value is the duration of the file (SHORT,
MEDIUM or LONG).

B<Note:> The result is cached, see L<pull_durations()> to refresh the data.

=item @reasons = $finder->exclude_file($test)

The input argument should be an L<Test2::Harness::Test> instance. This will
return a list of human readible reasons a test file should be excluded. If the
file should not be excluded the list will be empty.

This is a utility method that verifies the file is not in ant exclude
list/pattern. The reasons are provided back in case you need to inform the
user.

=item $bool = $finder->include_file($test)

The input argument should be an L<Test2::Harness::Test> instance. This is a
convenience method around C<exclude_file()>, it will return true when
C<exclude_file()> returns an empty list.

=item $arrayref = $finder->find_multi_project_files($plugins, $settings)

=item $arrayref = $finder->find_project_files($plugins, $settings, $search)

These do the heavy lifting for C<find_files>

The default C<find_files()> implementation is this:

    sub find_files {
        my $self = shift;
        my ($plugins, $settings) = @_;

        return $self->find_multi_project_files($plugins, $settings) if $self->multi_project;
        return $self->find_project_files($plugins, $settings, $self->search);
    }

Each one returns an arrayref of L<Test2::Harness::TestFile> instances.

Note that C<find_multi_project_files()> uses C<find_project_files()> internall,
once per project directory.

$plugins is a list of plugins, some may be class names, others may be
instances.

$settings is an L<Test2::Harness::Settings> instance.

$search is an arrayref of search paths.

=item $finder->munge_settings($settings, $options)

A callback that lets you munge settings and options.

=item $finder->pull_durations

This will fetch the durations data if ant was provided. This is a hashref of
relative test paths as keys where the value is the duration of the file (SHORT,
MEDIUM or LONG).

L<duration_data()> is a cached version of this. This method will refresh the
cache for the other.

=back

=head2 FROM SETTINGS

See L<App::Yath::Options::Finder> for up to date documentation on these.

=over 4

=item $finder->default_search

=item $finder->default_at_search

=item $finder->durations

=item $finder->maybe_durations

=item $finder->exclude_files

=item $finder->exclude_patterns

=item $finder->no_long

=item $finder->only_long

=item $finder->search

=item $finder->extensions

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
