package Test2::Formatter::EventStream;
use strict;
use warnings;

our $VERSION = '0.000002';

use Test2::Util::HashBase qw/fh no_numbers/;
use base 'Test2::Formatter';
use Test2::Harness::Fact;
use IO::Handle;
require Test2::Formatter::TAP;

sub init {
    my $self = shift;

    my $fh = $self->{+FH} ||= do {
        open(my $h, '>&', *STDOUT) or die "Could not clone STDOUT";

        my $old = select $h;
        $| = 1;
        select STDERR;
        $| = 1;
        select STDOUT;
        $| = 1;
        select $old;

        $h;
    };

    print $fh "T2_FORMATTER: EventStream\n";

    if(my $enc = delete $self->{encoding}) {
        $self->encoding($enc);
    }
}

sub write {
    my ($self, $e, $num) = @_;

    $num = undef if $self->{+NO_NUMBERS};

    my $json = Test2::Harness::Fact->from_event($e, number => $num)->to_json;
    my $fh = $self->{+FH};
    print $fh "T2_EVENT: $json\n";
    $fh->flush;
}

sub hide_buffered { 0 }

sub encoding {
    my $self = shift;

    if (@_) {
        my ($enc) = @_;

        my $fh = $self->{+FH};
        print $fh "T2_ENCODING: $enc\n";
        $fh->flush;

        # https://rt.perl.org/Public/Bug/Display.html?id=31923
        # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
        # order to avoid the thread segfault.
        if ($enc =~ m/^utf-?8$/i) {
            binmode($fh, ":utf8");
        }
        else {
            binmode($fh, ":encoding($enc)");
        }
    }
}

sub DESTROY {
    my $self = shift;
    my $fh = $self->{+FH} or return;
    eval { $fh->flush };
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::EventStream - Test2::Harness prefers this as a formatter.

=head1 DESCRIPTION

This formatter sends all L<Test2::Event> objects over STDOUT serialized as
JSON. Each event will appear on its own line with the C<T2_EVENT: > prefix.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
