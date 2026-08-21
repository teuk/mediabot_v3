#!/usr/bin/perl
# =============================================================================
#  Mediabot v3 - Framework de test des commandes IRC
#  Usage : perl t/test_commands.pl [--verbose] [--filter <pattern>] [--profile]
#           [--class <tag>] [--exclude-class <tag>]
#           [--class-summary] [--list-selected] [--fast] [--progress]
#           [--nick <nick>] [--host <host>] [--channel <chan>]
#           [--botnick <botnick>] [--cmdchar <char>]
# =============================================================================

BEGIN {
    require FindBin;
    unshift @INC, "$FindBin::Bin/lib";  # t/lib/
    unshift @INC, "$FindBin::Bin/..";   # racine projet
}

use strict;
use warnings;
use MockBot;
use MockIRC;
use MockMessage;
use MockUser;
use Getopt::Long;
use File::Basename;
use File::Temp qw(tempfile);
use Cwd qw(getcwd);
use POSIX qw(strftime);
use TAP::Parser;
use Time::HiRes ();
use IO::Handle ();
use TestClassifier qw(classify_test_file allowed_test_classes);
use FastValidation qw(
    fast_lane_reason
    select_fast_files
    validate_fast_lane_sentinels
);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# Mediabot.pm charge "use diagnostics" qui formate les warnings longuement.
# On le desactive juste avant chaque execution de closure (apres chargement).


# ---- Options CLI ------------------------------------------------------------
my $opt_verbose = 0;
my $opt_filter  = '';
my $opt_nick    = 'testuser';
my $opt_host    = 'test.host';
my $opt_channel = '#test';
my $opt_botnick = 'mediabot';
my $opt_cmdchar = '!';
my $opt_profile = 0;
my $opt_profile_top;
my @opt_classes;
my @opt_exclude_classes;
my $opt_class_summary = 0;
my $opt_list_selected = 0;
my $opt_fast = 0;
my $opt_progress = 0;
GetOptions(
    'verbose|v'   => \$opt_verbose,
    'filter|f=s'  => \$opt_filter,
    'nick|n=s'    => \$opt_nick,
    'host=s'      => \$opt_host,
    'channel|c=s' => \$opt_channel,
    'botnick|b=s' => \$opt_botnick,
    'cmdchar=s'   => \$opt_cmdchar,
    'profile'       => \$opt_profile,
    'profile-top=i' => \$opt_profile_top,
    'class=s@'      => \@opt_classes,
    'exclude-class=s@' => \@opt_exclude_classes,
    'class-summary' => \$opt_class_summary,
    'list-selected' => \$opt_list_selected,
    'fast'          => \$opt_fast,
    'progress'      => \$opt_progress,
) or die <<USAGE;
Usage: $0 [options]
  --verbose, -v          Afficher chaque test [OK]/[FAIL]
  --filter,  -f <pat>    Lancer uniquement les fichiers matching <pat>
  --nick,    -n <nick>   Pseudo par defaut (defaut: testuser)
  --host        <host>   Hostname par defaut (defaut: test.host)
  --channel, -c <chan>   Canal par defaut   (defaut: #test)
  --botnick, -b <name>   Pseudo du bot      (defaut: mediabot)
  --cmdchar     <char>   Caractere de commande (defaut: !)
  --profile              Mesurer le temps de chaque fichier de test
  --profile-top <n>      Afficher les n fichiers les plus lents (defaut: 20) ; implique --profile
  --class <tag>           Inclure les tests portant ce tag (repeatable/comma-separated)
  --exclude-class <tag>   Exclure les tests portant ce tag (repeatable/comma-separated)
  --class-summary         Afficher la classification selectionnee sans lancer les tests
  --list-selected         Lister les tests selectionnes/classes sans les lancer
  --fast                  Lane de validation rapide: PURE + sentinelles critiques
                          (ne remplace PAS la suite complete)
  --progress              Barre de progression compacte sur une seule ligne
                          (pourcentage par fichiers, compteur d'assertions reel)
  Classes: PURE, FILESYSTEM, PROCESS, DB, NETWORK
USAGE

if (defined $opt_profile_top) {
    die "--profile-top must be a positive integer\n" if $opt_profile_top < 1;
    $opt_profile = 1;
}
$opt_profile_top = 20 unless defined $opt_profile_top;

die "--progress cannot be combined with --verbose\n"
    if $opt_progress && $opt_verbose;

my %valid_test_class = map { $_ => 1 } allowed_test_classes();

sub _normalize_class_args {
    my ($label, @specs) = @_;
    my @out;
    my %seen;

    for my $spec (@specs) {
        for my $raw (split /,/, ($spec // '')) {
            $raw =~ s/^\s+|\s+$//g;
            next unless length $raw;
            my $class = uc($raw);
            die "Unknown $label class '$raw'. Allowed: "
                . join(', ', allowed_test_classes()) . "\n"
                unless $valid_test_class{$class};
            push @out, $class unless $seen{$class}++;
        }
    }

    return @out;
}

@opt_classes = _normalize_class_args('--class', @opt_classes);
@opt_exclude_classes =
    _normalize_class_args('--exclude-class', @opt_exclude_classes);

# ---- Classe d'assertion -----------------------------------------------------
package Assert;

# Legacy MB12x-MB20x case files receive an assertion callback and invoke it as
# $assert->($condition, $description), while newer cases use the Assert object
# methods directly. Make the same object callable so the static runner supports
# both test styles.
use overload
    '&{}' => sub {
        my ($self) = @_;
        return sub {
            my (@args) = @_;

            # A failed regex evaluated in list context contributes an empty
            # list, leaving only the description. Treat that shape as failure
            # instead of accepting a truthy description as an unnamed pass.
            if (@args == 1 && defined $args[0] && $args[0] !~ /\A(?:0|1)\z/) {
                $self->fail($args[0]);
                return;
            }

            $self->ok($args[0], $args[1]);
        };
    },
    fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless { verbose => $args{verbose} // 0, pass => 0, fail => 0 }, $class;
}

sub _result {
    my ($self, $ok, $desc, $extra) = @_;
    if ($ok) {
        $self->{pass}++;
        print "  [OK] $desc\n" if $self->{verbose};
    } else {
        $self->{fail}++;
        my $info = $extra ? " ($extra)" : '';
        print "  [FAIL] $desc$info\n";
    }

    # MB301: assertion methods must behave like Test::More predicates so
    # constructs such as ok(...) or diag(...) work predictably.
    return $ok ? 1 : 0;
}

sub ok {
    my ($self, $val, $desc) = @_;
    $self->_result($val ? 1 : 0, $desc // '(unnamed)',
        $val ? '' : 'got: ' . (defined $val ? "'$val'" : 'undef'));
}

sub is {
    my ($self, $got, $expected, $desc) = @_;
    my $ok = defined $got && defined $expected && $got eq $expected;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : 'got: ' . (defined $got ? "'$got'" : 'undef') . " expected: '$expected'");
}

sub isnt {
    my ($self, $got, $unexpected, $desc) = @_;
    my $ok = !defined $got || $got ne $unexpected;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : "got unexpected: '$got'");
}

sub like {
    my ($self, $got, $pattern, $desc) = @_;
    my $ok = defined $got && $got =~ /$pattern/;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : 'got: ' . (defined $got ? "'$got'" : 'undef') . " pattern: $pattern");
}

sub unlike {
    my ($self, $got, $pattern, $desc) = @_;
    my $ok = !defined $got || $got !~ /$pattern/;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : "unexpectedly matched '$pattern'");
}

sub pass { $_[0]->_result(1, $_[1] // '(pass)') }
sub fail { $_[0]->_result(0, $_[1] // '(fail)') }

sub diag {
    my ($self, @parts) = @_;
    my $text = join('', map { defined($_) ? $_ : 'undef' } @parts);
    $text =~ s/\r\n?/\n/g;
    $text =~ s/\n\z//;
    $text =~ s/^/# /mg;
    print "$text\n" if length $text;
    return 0;
}

sub total  { $_[0]->{pass} + $_[0]->{fail} }
sub passed { $_[0]->{pass} }
sub failed { $_[0]->{fail} }

# ---- Runner -----------------------------------------------------------------
package main;

sub make_bot {
    my (%args) = @_;
    my $default_nick = $opt_nick;
    my $user = $args{user} // MockUser->new(nick => $default_nick, level => 'Owner', auth => 1);
    return MockBot->new(
        mock_user   => $user,
        debug_level => $args{debug_level} // -1,
        botnick     => $args{botnick}     // $opt_botnick,
        cmd_char    => $args{cmd_char}    // $opt_cmdchar,
    );
}

sub make_msg_chan {
    my (%args) = @_;
    return MockMessage->from_channel(
        prefix  => $args{prefix}  // "$opt_nick!$opt_nick\@$opt_host",
        channel => $args{channel} // $opt_channel,
        text    => $args{text}    // '',
    );
}

sub make_msg_priv {
    my (%args) = @_;
    return MockMessage->from_private(
        prefix => $args{prefix} // "$opt_nick!$opt_nick\@$opt_host",
        text   => $args{text}   // '',
    );
}

# mb333-B1: Some historical case files are standalone TAP programs. They call exit()
# directly instead of returning a closure when loaded through do(). Loading one
# of those files in the runner process terminates the whole suite immediately,
# skips every later case, and can return success before the runner prints its
# final summary. MB333 isolates such cases in a subprocess and merges their TAP
# counts into the normal Assert totals.
sub _case_requires_isolation {
    my ($file) = @_;

    open my $fh, '<:encoding(UTF-8)', $file
        or return (1, "cannot inspect $file: $!");
    local $/;
    my $src = <$fh>;
    close $fh;

    return (1, 'empty or unreadable test source')
        unless defined $src && length $src;

    # MB335: classify by the file contract, not by words that may appear in
    # quoted probe programs. Native runner cases return a closure directly.
    return (0, 'runner closure')
        if $src =~ /^\s*return\s+sub\s*\{/m;

    # Hybrid cases expose a closure when loaded by this runner and execute a
    # standalone TAP footer only when called directly.
    return (0, 'caller-guarded runner closure')
        if $src =~ /^\s*my\s+\$[A-Za-z_]\w*\s*=\s*sub\s*\{/m
        && $src =~ /\b(?:if|unless)\s*\(\s*caller(?:\s*\(\s*\))?\s*\)/;

    # Test::More/Test2 and historical TAP scripts must run in their own Perl
    # process so their plan/done_testing/exit state cannot contaminate the
    # custom Assert runner or any later case.
    return (1, 'standalone TAP contract');
}

sub _run_isolated_tap_case {
    my ($file, $name, $assert) = @_;

    my $project_root = "$FindBin::Bin/..";

    my $pid = open(my $child, '-|');
    unless (defined $pid) {
        $assert->fail("$name: isolated launch - cannot fork: $!");
        return;
    }

    if ($pid == 0) {
        open STDERR, '>&', STDOUT
            or POSIX::_exit(254);
        chdir $project_root
            or do {
                print "Bail out! cannot chdir to $project_root: $!\n";
                POSIX::_exit(254);
            };
        no warnings 'exec';
        exec(
            $^X,
            "-I$FindBin::Bin/lib",
            "-I$project_root",
            $file,
        );
        print "Bail out! cannot exec $file: $!\n";
        POSIX::_exit(254);
    }

    local $/;
    my $output = <$child> // '';
    my $closed = close $child;
    my $status = $?;

    print $output;

    my $parser = TAP::Parser->new({ source => \$output });
    my ($tap_pass, $tap_fail, $tap_tests) = (0, 0, 0);

    while (my $result = $parser->next) {
        next unless $result->is_test;
        $tap_tests++;
        if ($result->is_ok) {
            $tap_pass++;
        }
        else {
            $tap_fail++;
        }
    }

    $assert->{pass} += $tap_pass;
    $assert->{fail} += $tap_fail;

    my @parse_errors = $parser->parse_errors;

    # Several historical standalone scripts emit valid ok/not-ok lines but no
    # explicit plan. Preserve that legacy contract when assertions were seen;
    # every other TAP parse error remains fatal.
    my @fatal_parse_errors = grep {
        !($tap_tests > 0 && /No plan found in TAP output/)
    } @parse_errors;

    if (@fatal_parse_errors) {
        my $detail = join('; ', @fatal_parse_errors);
        $assert->fail("$name: isolated TAP parse", $detail);
    }
    elsif ($tap_tests == 0) {
        $assert->fail("$name: isolated TAP", 'no TAP assertions found');
    }

    my $signal = $status & 127;
    my $exit   = $status >> 8;

    if ($signal) {
        $assert->fail("$name: isolated process - terminated by signal $signal");
    }
    elsif (!$closed || $exit != 0) {
        # A normal failing TAP case already contributes its not-ok assertions.
        # Add a process-level failure only when TAP did not explain the exit.
        if ($tap_fail == 0 && !@fatal_parse_errors) {
            $assert->fail("$name: isolated process - exit status $exit");
        }
    }

    return 1;
}

# ---- Profiling ---------------------------------------------------------------

my @profile_rows;

sub _record_profile_case {
    my (%args) = @_;
    return unless $opt_profile;

    my $elapsed = Time::HiRes::time() - $args{started};
    my $assertions = $args{assert}->total - $args{assert_before};
    my $failures   = $args{assert}->failed - $args{failed_before};

    push @profile_rows, {
        name       => $args{name},
        elapsed    => $elapsed,
        mode       => $args{mode} // 'runner',
        assertions => $assertions,
        failures   => $failures,
    };
}

sub _print_profile_report {
    return unless $opt_profile;

    my @sorted = sort {
        $b->{elapsed} <=> $a->{elapsed}
            || $a->{name} cmp $b->{name}
    } @profile_rows;

    my $count = scalar @sorted;
    my $limit = $opt_profile_top < $count ? $opt_profile_top : $count;
    my $sum = 0;
    $sum += $_->{elapsed} for @profile_rows;

    print "\nSlowest test files (top $limit of $count)\n";
    print "-" x 78 . "\n";
    print " #     seconds  mode       asserts  file\n";
    print "-" x 78 . "\n";

    for my $idx (0 .. $limit - 1) {
        my $row = $sorted[$idx];
        my $status = $row->{failures} ? '!' : ' ';
        printf "%s%2d  %9.3f  %-9s %7d  %s\n",
            $status,
            $idx + 1,
            $row->{elapsed},
            $row->{mode},
            $row->{assertions},
            $row->{name};
    }

    print "-" x 78 . "\n";
    printf "Profiled %d test file(s); cumulative case time %.3fs\n", $count, $sum;
    print "A leading '!' marks a file that contributed at least one failed assertion.\n";
}

# ---- Classification -----------------------------------------------------------

sub _classification_has_any {
    my ($info, $wanted) = @_;
    return 1 unless @$wanted;

    my %tag = map { $_ => 1 } @{ $info->{tags} // [] };
    return scalar grep { $tag{$_} } @$wanted;
}

sub _print_class_summary {
    my ($files, $info_by_file, $all_count) = @_;

    my %primary = map { $_ => 0 } allowed_test_classes();
    my %tagged  = map { $_ => 0 } allowed_test_classes();

    for my $file (@$files) {
        my $info = $info_by_file->{$file};
        $primary{ $info->{primary} }++;
        $tagged{$_}++ for @{ $info->{tags} };
    }

    print "\nTest classification summary\n";
    print "-" x 62 . "\n";
    printf "Selected: %d of %d discovered test file(s)\n",
        scalar(@$files), $all_count;
    print "\nPrimary class (one per file)\n";
    for my $class (allowed_test_classes()) {
        printf "  %-10s %4d\n", $class, $primary{$class};
    }

    print "\nCapability tags (overlap allowed)\n";
    for my $class (allowed_test_classes()) {
        printf "  %-10s %4d\n", $class, $tagged{$class};
    }

    print "\nClassification is conservative source-touchpoint metadata.\n";
    print "It is NOT a parallel-safety certification.\n";
}

sub _print_selected_tests {
    my ($files, $info_by_file) = @_;

    print "\nSelected test files\n";
    print "-" x 110 . "\n";
    printf "%-10s %-34s %-44s %s\n", 'primary', 'tags', 'selection', 'file';
    print "-" x 110 . "\n";

    for my $file (@$files) {
        my $info = $info_by_file->{$file};
        my $selection = $opt_fast
            ? (fast_lane_reason($file, $info) // 'filtered fast lane')
            : 'normal selection';
        printf "%-10s %-34s %-44s %s\n",
            $info->{primary},
            join(',', @{ $info->{tags} }),
            $selection,
            basename($file);
    }
}

# ---- Chargement des cas de test ---------------------------------------------

my $assert   = Assert->new(verbose => $opt_verbose);
my $ts_start = time();

# Chemin absolu vers t/cases/ — indépendant du CWD
my $cases_dir = "$FindBin::Bin/cases";
my @all_test_files = sort glob("$cases_dir/*.t");
my %case_classification;

for my $file (@all_test_files) {
    my ($isolate) = _case_requires_isolation($file);
    $case_classification{$file} =
        classify_test_file($file, isolated => $isolate ? 1 : 0);
}

my @test_files = @all_test_files;

if ($opt_fast) {
    my ($sentinels_ok, $missing) =
        validate_fast_lane_sentinels(\@all_test_files);

    die "Fast validation sentinel(s) missing: "
        . join(', ', @$missing)
        . "\nRefusing to run a silently weakened fast lane.\n"
        unless $sentinels_ok;

    @test_files =
        select_fast_files(\@test_files, \%case_classification);
}

if ($opt_filter) {
    my $filter_re = eval { qr/$opt_filter/i };
    if (!$filter_re) {
        my $err = $@ || 'unknown regex error';
        $err =~ s/\s+\z//;
        die "Invalid --filter regex '$opt_filter': $err\n";
    }
    @test_files = grep { basename($_) =~ $filter_re } @test_files;
}

if (@opt_classes) {
    @test_files = grep {
        _classification_has_any($case_classification{$_}, \@opt_classes)
    } @test_files;
}

if (@opt_exclude_classes) {
    @test_files = grep {
        !_classification_has_any(
            $case_classification{$_},
            \@opt_exclude_classes,
        )
    } @test_files;
}

if (!@test_files) {
    print "Aucun fichier de test selectionne dans $cases_dir\n";
    exit 1;
}

if ($opt_class_summary) {
    _print_class_summary(
        \@test_files,
        \%case_classification,
        scalar(@all_test_files),
    );
}

if ($opt_list_selected) {
    _print_selected_tests(\@test_files, \%case_classification);
}

exit 0 if $opt_class_summary || $opt_list_selected;

if ($opt_fast) {
    print "\nFast validation lane\n";
    print "-" x 60 . "\n";
    printf "Selected: %d of %d discovered test file(s)\n",
        scalar(@test_files), scalar(@all_test_files);
    print "Policy  : fast PURE - reviewed slow cases + mandatory sentinels\n";
    print "Scope   : development validation; NOT equivalent to the full suite\n";
}

sub _filter_case_load_warning {
    my ($warning) = @_;

    # Case files share package main inside this legacy runner. Helpers such as
    # _slurp and _strip are intentionally reused by several independent cases.
    return if $warning =~ /\ASubroutine \S+ redefined at /;
    return if $warning =~ /\APrototype mismatch:/;
    return if $warning =~ /used only once/i;

    warn $warning;
}

my @progress_failure_details;
my ($progress_console_out, $progress_console_err, $progress_capture_fh);
my $progress_done = 0;
my $progress_render_width = 0;

sub _progress_render {
    my (%args) = @_;
    return unless $opt_progress;

    my $fh      = $args{fh}      // $progress_console_out;
    my $done    = $args{done}    // 0;
    my $total   = $args{total}   // 0;
    my $tests   = $args{tests}   // 0;
    my $current = $args{current} // '';
    $current = '' if $total > 0 && $done >= $total;

    my $width = 20;
    my $ratio = $total > 0 ? $done / $total : 1;
    $ratio = 0 if $ratio < 0;
    $ratio = 1 if $ratio > 1;

    my $percent = int(($ratio * 100) + 0.5);
    my $filled = int($ratio * $width);
    my $bar;

    if ($filled >= $width) {
        $bar = '=' x $width;
    }
    elsif ($filled > 0) {
        $bar = ('=' x ($filled - 1)) . '>' . (' ' x ($width - $filled));
    }
    else {
        $bar = ' ' x $width;
    }

    my $line = sprintf "[%s] %3d%% [%d/%d files | %d tests]%s",
        $bar, $percent, $done, $total, $tests,
        length($current) ? " | running: $current" : "";

    my $padding = $progress_render_width > length($line)
        ? ' ' x ($progress_render_width - length($line))
        : '';

    print {$fh} "\r$line$padding";
    print {$fh} "\r$line" if length($padding);
    $progress_render_width = length($line)
        if length($line) > $progress_render_width;
    $fh->flush();
}

sub _progress_capture_take {
    return '' unless $opt_progress && $progress_capture_fh;

    STDOUT->flush();
    STDERR->flush();

    seek($progress_capture_fh, 0, 0)
        or die "Cannot rewind progress capture: $!\n";
    local $/;
    my $output = <$progress_capture_fh> // '';

    truncate($progress_capture_fh, 0)
        or die "Cannot truncate progress capture: $!\n";
    seek($progress_capture_fh, 0, 0)
        or die "Cannot reset progress capture: $!\n";

    $output =~ s/\r\n?/\n/g;
    $output =~ s/\s+\z//;
    return $output;
}

sub _progress_begin {
    return unless $opt_progress;

    open $progress_console_out, '>&', \*STDOUT
        or die "Cannot duplicate STDOUT for progress mode: $!\n";
    open $progress_console_err, '>&', \*STDERR
        or die "Cannot duplicate STDERR for progress mode: $!\n";

    ($progress_capture_fh) = tempfile(
        'mediabot_test_progress_XXXX',
        TMPDIR => 1,
        UNLINK => 1,
    );

    open STDOUT, '>&', $progress_capture_fh
        or die "Cannot redirect STDOUT for progress mode: $!\n";
    open STDERR, '>&', $progress_capture_fh
        or die "Cannot redirect STDERR for progress mode: $!\n";

    _progress_render(
        done  => 0,
        total => scalar(@test_files),
        tests => $assert->total,
    );
}

sub _progress_after_case {
    my (%args) = @_;
    return unless $opt_progress;

    my $output = _progress_capture_take();
    if ($assert->failed > ($args{failed_before} // 0)) {
        push @progress_failure_details, {
            name   => $args{name},
            output => $output,
        };
    }

    $progress_done++;
    _progress_render(
        done  => $progress_done,
        total => scalar(@test_files),
        tests => $assert->total,
    );
}

sub _progress_finish {
    return unless $opt_progress;

    STDOUT->flush();
    STDERR->flush();

    open STDOUT, '>&', $progress_console_out
        or die "Cannot restore STDOUT after progress mode: $!\n";
    open STDERR, '>&', $progress_console_err
        or die "Cannot restore STDERR after progress mode: $!\n";

    print "\n";

    return unless @progress_failure_details;

    print "\nFailure details\n";
    print "-" x 60 . "\n";

    for my $row (@progress_failure_details) {
        if (length $row->{output}) {
            print "$row->{output}\n\n";
        }
        else {
            print "[ $row->{name} ]\n(no captured diagnostics)\n\n";
        }
    }
}

_progress_begin();

my $progress_case_failed_before = 0;
my $progress_case_name = '';

for my $file (@test_files) {
    $progress_case_failed_before = $assert->failed;
    $progress_case_name = basename($file);
    my $name = basename($file);
    _progress_render(
        done    => $progress_done,
        total   => scalar(@test_files),
        tests   => $assert->total,
        current => $name,
    );
    my $case_started = Time::HiRes::time();
    my $assert_before = $assert->total;
    my $failed_before = $assert->failed;
    my $profile_mode = 'runner';
    print "\n[ $name ]\n";

    my ($isolate, $isolate_reason) = _case_requires_isolation($file);
    if ($isolate) {
        $profile_mode = 'isolated';
        print "  (isolated standalone TAP case: $isolate_reason)\n" if $opt_verbose;
        _run_isolated_tap_case($file, $name, $assert);
        _record_profile_case(
            name          => $name,
            mode          => $profile_mode,
            started       => $case_started,
            assert        => $assert,
            assert_before => $assert_before,
            failed_before => $failed_before,
        );
        next;
    }

    # FindBin was initialized for this runner. Legacy loaded cases expect $Bin
    # to be their own t/cases directory, so localize it around do().
    local $FindBin::Bin = dirname($file);
    local $FindBin::RealBin = $FindBin::Bin;
    my $code;
    {
        # The warning filter must be active before do() compiles the case.
        local $SIG{__WARN__} = \&_filter_case_load_warning;
        $code = do $file;
    }
    if ($@) {
        print "  ERREUR de chargement : $@\n";
        $assert->fail("$name: chargement");
        _record_profile_case(
            name          => $name,
            mode          => 'load-error',
            started       => $case_started,
            assert        => $assert,
            assert_before => $assert_before,
            failed_before => $failed_before,
        );
        next;
    }
    if (ref $code eq 'CODE') {
        eval { diagnostics->disable } if $diagnostics::VERSION;
        local $SIG{__WARN__} = sub {
            my $w = shift;
            return if $w =~ /uninitialized|redefine|prototype|only once/i;
            warn $w;
        };
        # MB301: a broken case must fail that case, not abort the whole runner.
        my $executed = eval {
            $code->($assert, \&make_bot, \&make_msg_chan, \&make_msg_priv);
            1;
        };

        if (!$executed) {
            my $err = $@ || 'unknown test execution error';
            $err =~ s/\r\n?/\n/g;
            $err =~ s/\s+\z//;
            $err =~ s/\n/\n  /g;
            print "  ERREUR d'execution : $err\n";
            $assert->fail("$name: execution");
        }
    } else {
        $profile_mode = 'skip';
        print "  (pas de sous-routine retournee, skip)\n";
    }

    _record_profile_case(
        name          => $name,
        mode          => $profile_mode,
        started       => $case_started,
        assert        => $assert,
        assert_before => $assert_before,
        failed_before => $failed_before,
    );
}
continue {
    _progress_after_case(
        name          => $progress_case_name,
        failed_before => $progress_case_failed_before,
    );
}

_progress_finish();

# ---- Resume -----------------------------------------------------------------

my $elapsed = time() - $ts_start;
my $total   = $assert->total;
my $passed  = $assert->passed;
my $failed  = $assert->failed;

_print_profile_report();

print "\n" . "=" x 60 . "\n";
if ($failed == 0) {
    printf "PASSED : %d/%d  (%ds)\n", $passed, $total, $elapsed;
} else {
    printf "FAILED : %d/%d  (%d passed)  (%ds)\n", $failed, $total, $passed, $elapsed;
}
print "=" x 60 . "\n";

exit($failed > 0 ? 1 : 0);