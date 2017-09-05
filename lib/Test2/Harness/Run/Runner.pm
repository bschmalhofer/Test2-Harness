package Test2::Harness::Run::Runner;
use strict;
use warnings;

our $VERSION = '0.001005';

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use Config qw/%Config/;
use IPC::Open3 qw/open3/;
use List::Util qw/none sum/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/open_file write_file_atomic/;

use Test2::Harness::Run();
use Test2::Harness::Run::Queue();

use Test2::Harness::Job();
use Test2::Harness::Job::Runner();

use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::File::JSONL();

use File::Spec();

use Test2::Harness::Util::HashBase qw{
    -dir
    -run
    -run_file

    -err_log -out_log
    -_exit
    -pid

    -wait_time

    -_next

    -job_runner_class

    -jobs_file  -jobs
    -queue_file -queue
    -state_file -state
    -hup
};

sub init {
    my $self = shift;

    croak "'dir' is a required attribute" unless $self->{+DIR};

    my $dir = File::Spec->rel2abs($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    my $run_file = $self->{+RUN_FILE} ||= File::Spec->catfile($dir, 'run.json');

    if (!$self->{+RUN} && -f $run_file) {
        my $rf = Test2::Harness::Util::File::JSON->new(name => $run_file);
        $self->{+RUN} = Test2::Harness::Run->new(%{$rf->read()});
    }

    croak "'run' is a required attribute" unless $self->{+RUN};

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+JOB_RUNNER_CLASS} ||= 'Test2::Harness::Job::Runner';

    $self->{+ERR_LOG}   = File::Spec->catfile($dir, 'error.log');
    $self->{+OUT_LOG}   = File::Spec->catfile($dir, 'output.log');

    $self->{+STATE_FILE} = File::Spec->catfile($dir, 'state.json');

    $self->{+JOBS_FILE} = File::Spec->catfile($dir, 'jobs.jsonl');
    $self->{+JOBS} = Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE});

    $self->{+QUEUE_FILE} = File::Spec->catfile($dir, 'queue.jsonl');
    $self->{+QUEUE} = Test2::Harness::Run::Queue->new(file => $self->{+QUEUE_FILE});

    if ($self->{+RUN}->job_count < 2) {
        $self->{+_NEXT} = 'next_by_stamp';
    }
    elsif ($self->{+RUN}->finite) {
        $self->{+_NEXT} = 'next_finite';
    }
    else {
        $self->{+_NEXT} = 'next_fair';
    }

    $self->{+DIR} = $dir;
}

sub find_spawn_script {
    my $self = shift;

    my $script = $ENV{T2_HARNESS_SPAWN_SCRIPT} || 'yath-spawn';
    return $script if -f $script;

    if ($0 && $0 =~ m{(.*)\byath(-.*)?$}) {
        return "$1$script" if -f "$1$script";
    }

    # Do we have the full path?
    # Load IPC::Cmd only if needed, it indirectly loads version.pm which really
    # screws things up...
    require IPC::Cmd;
    if(my $out = IPC::Cmd::can_run($script)) {
        return $out;
    }

    die "Could not find '$script' in execution path";
}

sub find_inc {
    my $self = shift;

    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $inc = $INC{"Test2/Harness/Run/Runner.pm"};
    $inc =~ s{/Test2/Harness/Run/Runner\.pm$}{}g;
    return File::Spec->rel2abs($inc);
}

sub cmd {
    my $self = shift;

    my $script = $self->find_spawn_script;
    my $inc    = $self->find_inc;

    return (
        $^X,
        "-I$inc",
        $script,
        $self->{+DIR},
    );
}

sub spawn {
    my $self = shift;

    my $run = $self->{+RUN};

    my $rf = Test2::Harness::Util::File::JSON->new(name => $self->{+RUN_FILE});
    $rf->write($run->TO_JSON);

    my $err_log = open_file($self->{+ERR_LOG}, '>');
    my $out_log = open_file($self->{+OUT_LOG}, '>');

    my $env = $run->env_vars;
    local $ENV{$_} = $env->{$_} for keys %$env;

    my $pid = open3(
        undef, ">&" . fileno($out_log), ">&" . fileno($err_log),
        $self->cmd,
    );

    $self->{+PID} = $pid;

    return $pid;
}

sub wait {
    my $self = shift;
    my ($flags) = @_;

    return if defined $self->{+_EXIT};

    my $pid = $self->{+PID} or croak "No PID, cannot wait";
    my $check = waitpid($pid, $flags || 0);
    my $exit = ($? >> 8);

    return if $check == 0;
    die "Spawn process was already reaped" if $check == -1;

    $self->{+_EXIT} = $exit;

    return;
}

sub exit {
    my $self = shift;

    return $self->{+_EXIT} if defined $self->{+_EXIT};

    $self->wait(WNOHANG);

    return $self->{+_EXIT};
}

sub preload {
    my $self = shift;

    my $run = $self->{+RUN};
    my $list = $run->preload;

    local @INC = ($run->all_libs, @INC);

    require Test2::API;
    Test2::API::test2_start_preload();

    for my $mod (@$list) {
        my $file = pkg_to_file($mod);
        require $file;
    }
}

sub start {
    my $self = shift;

    my $run = $self->{+RUN};

    my $orig = File::Spec->curdir();
    if (my $chdir = $run->chdir) {
        chdir($chdir);
    }

    my $pidfile = File::Spec->catfile($self->{+DIR}, 'PID');
    write_file_atomic($pidfile, "$$");

    my $env = $run->env_vars;
    local $ENV{$_} = $env->{$_} for keys %$env;

    my $sig;
    my $handle_sig = sub {
        my ($got_sig) = @_;

        # Already being handled
        return if $sig;

        $sig = $sig;

        die "Runner cought SIG$sig, Attempting to shut down cleanly...\n";
    };

    local $SIG{INT}  = sub { $handle_sig->('INT') };
    local $SIG{TERM} = sub { $handle_sig->('TERM') };
    local $SIG{HUP}  = sub {
        print STDERR "Runner cought SIGHUP, saving state and reloading...\n";
        $self->{+HUP} = 1;
    };

    $self->preload if $run->preload;

    my $out;
    my $ok = eval { $out = $self->_start(@_); 1 };
    my $err = $@;

    chdir($orig);

    return $out if $ok;

    warn $err;

    $self->kill_jobs($sig || 'TERM');
    $self->wait_jobs(WNOHANG);

    CORE::exit($SIG ? $SIG eq 'TERM' ? 143 : $SIG eq 'INT' ? 130 : 255 : 255);
}

sub _start {
    my $self = shift;

    my $run   = $self->{+RUN};
    my $queue = $self->{+QUEUE};

    if (-f $self->{+STATE_FILE}) {
        $self->{+STATE} = Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE})->read;
    }
    else {
        $self->{+STATE} = {
            running  => {long => [], medium => [], general => [], isolation => []},
            pending  => {long => [], medium => [], general => [], isolation => []},
            position => 0,
        };
    }

    my $state = $self->{+STATE};
    $queue->seek($state->{position});

    while (1) {
        $self->respawn if $self->{+HUP};

        my $task = $self->next or last;

        my $runfile = $self->run_job($task);
        return $runfile if $runfile;
    }

    $self->wait_jobs;

    return undef;
}

sub respawn {
    my $self = shift;

    my $state = $self->{+STATE};

    Test2::Harness::Util::File::JSON->new(name => $self->{+STATE_FILE})->write($state);

    exec($self->cmd);
    warn "Should not get here, respawn failed";
    CORE::exit(255);
}

sub wait_jobs {
    my $self = shift;
    my ($flags) = @_;

    my $running = $self->{+STATE}->{running};

    for my $cat (values %$running) {
        my @keep;

        for my $set (@$cat) {
            my ($pid, $exit_file) = @$set;
            my $got = waitpid($pid, $flags || 0);
            my $ret = $? >> 8;

            if(!$got) {
                push @keep => $set;
            }
            elsif ($got == $pid) {
                write_file_atomic($exit_file, $ret);
            }
            else {
                warn "Could not reap pid $pid, waitpid returned $got";
            }
        }

        @$cat = @keep;
    }

    return;
}

sub kill_jobs {
    my $self = shift;
    my ($sig) = @_;

    my $running = $self->{+STATE}->{running};
    for my $cat (values %$running) {
        for my $set (@$cat) {
            my ($pid) = @_;
            kill($sig, $pid) or warn "Could not kill pid $pid";
        }
    }

    return;
}

sub run_job {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id};
    my $file = $task->{file};

    unless ($job_id) {
        warn "Task does not have a job ID, skipping";
        next;
    }

    unless ($file) {
        warn "Task does not have a file, skipping";
        next;
    }

    my $run = $self->{+RUN};

    my $dir = File::Spec->catdir($self->{+DIR}, $job_id);
    mkdir($dir) or die "Could not create job directory '$dir': $!";
    my $tmp = File::Spec->catdir($dir, 'tmp');
    mkdir($tmp) or die "Coult not create job temp directory '$tmp': $!";

    my $start_file = File::Spec->catfile($dir, 'start');
    my $exit_file  = File::Spec->catfile($dir, 'exit');
    my $file_file  = File::Spec->catfile($dir, 'file');

    write_file_atomic($file_file, $file);
    write_file_atomic($start_file, time());

    my @libs = $run->all_libs;
    unshift @libs => @{$task->{libs}} if $task->{libs};
    my $env = {
        %{$run->env_vars},
        TMPDIR => $tmp,
        TEMPDIR => $tmp,
        %{$task->{env_vars} || {}},
        PERL_USE_UNSAFE_INC => $task->{unsafe_inc},
    };

    my $p5l = join $Config{path_sep} => ($env->{PERL5LIB} || ()), @libs;
    $env->{PERL5LIB} = $p5l;

    # If any are false, then the answer is false.
    my $stream  = none { defined $_ && !$_ } $task->{use_stream},  $run->use_stream,  1;
    my $timeout = none { defined $_ && !$_ } $task->{use_timeout}, $run->use_timeout, 1;
    my $fork    = none { defined $_ && !$_ } $task->{use_fork}, $task->{use_preload}, $run->use_fork, 1;

    my $job = Test2::Harness::Job->new(
        # These can be overriden by the task
        times => $run->times,

        %$task,

        # These win out over task data, most are merged with task data here
        # or above.
        use_stream => $stream,
        use_fork   => $fork,
        timeout    => $timeout,
        job_id     => $job_id,
        file       => $file,
        env_vars   => $env,
        libs       => \@libs,
        switches   => [@{$run->switches}, @{$task->{switches} || []}],
        args       => [@{$run->args}, @{$task->{args} || []}],
        input => $task->{input} || $run->input,
        chdir => $task->{chdir} || $run->chdir,
    );

    my $runner = $self->{+JOB_RUNNER_CLASS}->new(
        job => $job,
        dir => $dir,
        via => $fork ? ['Fork', 'Open3'] : ['Open3'],
    );

    my ($pid, $runfile) = $runner->run;
    return $runfile if $runfile; # In child process

    # In parent
    my $category = $task->{category};
    $category = 'general' unless $category && $self->{+STATE}->{running}->{$category};

    $self->{+JOBS}->write({ %{$job->TO_JSON}, pid => $pid });
    push @{$self->{+STATE}->{running}->{$category}} => [$pid, $exit_file];

    return;
}

sub next {
    my $self = shift;

    my $wait_time = $self->wait_time;
    my $max = $self->{+RUN}->job_count;
    my $meth = $self->{+_NEXT};
    my $state = $self->{+STATE};

    while(1) {
        $self->wait_jobs(WNOHANG);
        $self->poll_jobs();

        return if $state->{ended} && !$self->pending;

        # Do not get next if we are at/over capacity, or have an isolated test running
        my $running = $self->running;
        if ($max > $running && !@{$state->{running}->{isolation}}) {
            my $next = $self->$meth($running, $max);
            return $next if $next;
        }

        sleep($wait_time) if $wait_time;
    }
}

sub running {
    my $self = shift;
    my $state = $self->{+STATE};
    return sum(map { scalar(@$_) } values %{$state->{running}});
}

sub pending {
    my $self = shift;
    my $state = $self->{+STATE};
    return sum(map { scalar(@$_) } values %{$state->{pending}});
}

sub _cats_by_stamp {
    my $self = shift;
    my $state = $self->{+STATE};
    my $pending = $state->{pending};
    return sort { $pending->{$a}->[0]->{stamp} <=> $pending->{$b}->[0]->{stamp} } grep { @{$pending->{$_}} } keys %$pending;
}

sub next_by_stamp {
    my $self = shift;
    my ($cat) = $self->_cats_by_stamp;
    return unless $cat;
    return shift(@{$self->{+STATE}->{pending}->{$cat}});
}

sub next_finite {
    my $self = shift;
    my ($running, $max) = @_;

    my $state = $self->{+STATE};

    my $p_gen = $state->{pending}->{general};
    my $p_med = $state->{pending}->{medium};
    my $p_lng = $state->{pending}->{long};
    my $p_iso = $state->{pending}->{iso};

    # If we have more than 1 slot available prefer a longer job
    if ($running < $max - 1) {
        return shift @$p_lng if @$p_lng;
        return shift @$p_med if @$p_med;
    }

    # Fallback with shortest first
    return shift @$p_gen if @$p_gen;
    return shift @$p_lng if @$p_lng;
    return shift @$p_med if @$p_med;

    # Next comes isolation, so we cannot pick one if anything is running.
    return if $running;

    return shift @$p_iso;
}

sub next_fair {
    my $self = shift;
    my ($running, $max) = @_;

    my @cats = $self->_cats_by_stamp;
    return unless @cats;

    my $state = $self->{+STATE};

    my $r_lng = $state->{running}->{long};
    my $r_med = $state->{running}->{long};

    # Do not fill all slots with 'long' or 'medium' jobs
    shift @cats while @cats > 1    # Do not change if this is the only category
        && ($cats[-1] eq 'long' || $cats[-1] eq 'medium')    # Only change if long/medium
        && sum(@$r_lng, @$r_med) >= $max - 1;                # Only change if the sum of running long+medium is more than max - 1

    my ($cat) = @cats;

    # Next one up requires isolation :-(
    if ($cat eq 'iso') {
        my $p_gen = $state->{pending}->{general};
        my $p_iso = $state->{pending}->{iso};

        # If we have something long running then go ahead and start general tasks, but nothing longer
        return shift @$p_gen if @{$state->{running}->{long}} && @$p_gen;

        # Cannot run the iso yet
        return if $running;

        # Now run the iso
        return shift @$p_iso;
    }

    # Return the next item by time recieved
    return shift @{$state->{pending}->{$cat}};
}

sub poll_jobs {
    my $self = shift;
    my $queue = $self->{+QUEUE};

    my $state = $self->{+STATE};
    my $p = $state->{pending};

    for my $item ($queue->poll) {
        my ($spos, $epos, $task) = @$item;

        $state->{position} = $epos;

        if (!$task) {
            $state->{ended} = 1;
            next;
        }

        my $cat = $task->{category};
        $cat = 'general' unless $cat && $self->{+STATE}->{running}->{$cat};

        push @{$p->{$cat}} => $task;
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Run::Runner - Logic for executing a test run.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
