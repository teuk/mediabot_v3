use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT :flock);
use Errno qw(EACCES);
use IO::Handle ();
use POSIX ();
use Cwd qw(getcwd);
use lib '.';

our $fail_config_rename;
BEGIN {
    # A real publication failure, without depending on the test user's UID.
    *CORE::GLOBAL::rename = sub ($$) {
        if ($main::fail_config_rename) { $! = EACCES; return 0; }
        return CORE::rename($_[0], $_[1]);
    };
}
use Mediabot::Conf;

my $root = tempdir(CLEANUP => 1);
my $initial = "[main]\nVALUE=old\nKEEP=yes\n[custom]\nLIST=one, two\n";
sub put_config {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die 'fixture write';
    print {$fh} $text or die 'fixture print';
    close $fh or die 'fixture close';
}
sub read_config {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die 'fixture read';
    local $/;
    return <$fh>;
}
sub fixture {
    my ($name, $mode) = @_;
    my $dir = "$root/$name";
    mkdir $dir or die 'fixture directory';
    my $path = "$dir/bot.conf";
    put_config($path, $initial);
    chmod($mode // 0600, $path) or die 'fixture mode';
    return ($path, Mediabot::Conf->new({}, $path));
}
sub no_temps {
    my ($path) = @_;
    $path =~ s{/[^/]+\z}{};
    opendir my $dh, $path or die 'fixture listing';
    my @temps = grep { /^\.mediabot-conf-/ } readdir $dh;
    closedir $dh;
    return @temps == 0;
}

for my $mode (0600, 0640) {
    my ($path, $conf) = fixture("normal-$mode", $mode);
    my @old = stat($path);
    $conf->set('main.VALUE', 'new');
    ok($conf->save(), 'successful save returns a definite success');
    my $read = Mediabot::Conf->new({}, $path);
    is($read->get('main.VALUE'), 'new', 'changed value survives a real re-read');
    is($read->get('main.KEEP'), 'yes', 'another key survives publication');
    is_deeply($read->get('custom.LIST'), ['one', 'two'], 'custom section and list semantics survive');
    my @new = stat($path);
    is($new[2] & 07777, $mode, 'existing configuration mode is preserved');
    is_deeply([@new[4,5]], [@old[4,5]], 'configuration owner and group are preserved');
    isnt($new[1], $old[1], 'publication replaces the complete inode');
    $conf->set('main.VALUE', 'again');
    ok($conf->save(), 'same object can save repeatedly after publication');
    is(Mediabot::Conf->new({}, $path)->get('main.VALUE'), 'again', 'repeat save refreshes its revision');
    ok(no_temps($path), 'successful save removes its temporary file');
}

{
    my ($path, $conf) = fixture('literal-values');
    my %values = (
        'custom.PHRASE' => 'Be brief, clear and helpful.',
        'custom.QUOTES' => 'say "yes"',
        'custom.PATH' => 'C:\\some\\directory',
        'custom.SPACES' => '  keep both ends  ',
        'custom.LIST' => ['one,two', 'three four', 'a\\b'],
    );
    $conf->set($_, $values{$_}) for keys %values;
    local $Config::Simple::USEQQ = 0;
    ok($conf->save(), 'literal-value fixture publishes through the real serializer');
    is($Config::Simple::USEQQ, 0, 'strict quoting does not mutate the dependency global setting');
    my $readback = Mediabot::Conf->new({}, $path);
    for my $key (sort keys %values) {
        is_deeply($readback->get($key), $values{$key}, 'literal value round-trips: '.$key);
    }
}

my $control_case = 0;
for my $value ("line\nbreak", "carriage\rreturn", "nul\x00byte") {
    my ($path, $conf) = fixture('controls-'.++$control_case);
    $conf->set('custom.VALUE', $value);
    ok(!eval { $conf->save(); 1 }, 'unsupported control characters are refused before INI publication');
    is(read_config($path), $initial, 'control-character refusal preserves the complete configuration');
    ok(no_temps($path), 'control-character refusal leaves no temporary content');
}

{
    my ($path, $conf) = fixture('caller-array');
    my @input = ("line\nbreak", 'plain');
    $conf->set('custom.LIST', \@input);
    is($input[0], "line\nbreak", 'set does not rewrite caller-owned list elements');
    ok(!eval { $conf->save(); 1 }, 'list normalization cannot hide structural controls from save validation');
    is(read_config($path), $initial, 'invalid list input never changes the active file');
}

{
    my ($path, $conf) = fixture('partial-write');
    my $before = read_config($path);
    $conf->set('main.VALUE', 'pending');
    my $temp_mode;
    {
        no warnings 'redefine';
        local *Config::Simple::write = sub {
            my ($cfg, $target) = @_;
            $temp_mode = (stat($target))[2] & 0777;
            put_config($target, "[main]\nVALUE=partial\n");
            return undef;
        };
        ok(!eval { $conf->save(); 1 }, 'partial serializer failure is propagated');
    }
    is(read_config($path), $before, 'partial serialization never truncates the active file');
    is($temp_mode, 0600, 'serialization starts in a private temporary file');
    is($conf->get('main.VALUE'), 'pending', 'failed save retains explicit pending in-memory values');
    ok(no_temps($path), 'failed serialization removes partial temporary content');
    ok($conf->save(), 'retry succeeds when the I/O failure is removed');
}

{
    my ($path, $conf) = fixture('serializer-exception');
    $conf->set('main.VALUE', 'pending');
    my $error;
    {
        no warnings 'redefine';
        local *Config::Simple::write = sub { die "PRIVATE_CONFIG_CONTENT\n" };
        eval { $conf->save() }; $error = $@;
    }
    ok(length($error), 'serializer exceptions fail the save');
    unlike($error, qr/PRIVATE_CONFIG_CONTENT/, 'save exceptions do not reveal serializer content');
    is(read_config($path), $initial, 'serializer exceptions preserve original bytes');
    ok(no_temps($path), 'serializer exceptions remove temporary files');
}

{
    my ($path, $conf) = fixture('rename-failure');
    $conf->set('main.VALUE', 'pending');
    local $fail_config_rename = 1;
    ok(!eval { $conf->save(); 1 }, 'publication failure is reported');
    is(read_config($path), $initial, 'rename failure preserves original bytes');
    ok(no_temps($path), 'rename failure removes the completed temporary file');
}

{
    my ($path, $conf) = fixture('sync-failure');
    $conf->set('main.VALUE', 'pending');
    {
        no warnings 'redefine';
        local *IO::Handle::sync = sub { return undef };
        ok(!eval { $conf->save(); 1 }, 'pre-publication sync failure is reported');
    }
    is(read_config($path), $initial, 'sync failure preserves original bytes');
    ok(no_temps($path), 'sync failure removes its temporary file');
}

{
    my ($path, $first) = fixture('two-objects');
    my $second = Mediabot::Conf->new({}, $path);
    $first->set('main.VALUE', 'first'); $first->save();
    $second->set('main.VALUE', 'second');
    ok(!eval { $second->save(); 1 }, 'a stale second object cannot overwrite a committed writer');
    is(Mediabot::Conf->new({}, $path)->get('main.VALUE'), 'first', 'first writer remains on disk');
    $second->reload(); $second->set('main.VALUE', 'reapplied');
    ok($second->save(), 'reload and explicit reapplication resolve a revision conflict');
}

{
    my ($path, $conf) = fixture('operator-edit');
    my @before = stat($path);
    (my $edited = $initial) =~ s/VALUE=old/VALUE=ops/;
    put_config($path, $edited); utime($before[8], $before[9], $path);
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'same-size external edit is detected even with restored timestamps');
    is(read_config($path), $edited, 'operator edit is retained byte for byte');
}

{
    my ($path, $conf) = fixture('edit-during-save');
    my $write = Config::Simple->can('write');
    (my $edited = $initial) =~ s/VALUE=old/VALUE=ops/;
    {
        no warnings 'redefine';
        local *Config::Simple::write = sub {
            my $result = $write->(@_);
            put_config($path, $edited);
            return $result;
        };
        $conf->set('main.VALUE', 'bot');
        ok(!eval { $conf->save(); 1 }, 'an operator edit during preparation prevents publication');
    }
    is(read_config($path), $edited, 'last pre-publication revision check protects the external edit');
    ok(no_temps($path), 'concurrent-edit refusal removes prepared temporary content');
}

{
    my ($path, $conf) = fixture('busy-lock');
    sysopen my $lock, "$path.lock", O_RDWR|O_CREAT, 0600 or die 'fixture lock';
    flock($lock, LOCK_EX|LOCK_NB) or die 'fixture flock';
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'busy writer lock fails immediately instead of blocking the IRC loop');
    is(read_config($path), $initial, 'busy lock leaves active configuration unchanged');
    close $lock;
    ok($conf->save(), 'lock is available for a later explicit retry');
    is((stat("$path.lock"))[2] & 0777, 0600, 'persistent writer lock is private');
}

{
    my ($path, $conf) = fixture('symlink-config');
    my $alias = "$root/symlink-config/alias.conf";
    symlink 'bot.conf', $alias or die 'fixture symlink';
    my $through_link = Mediabot::Conf->new({}, $alias);
    $through_link->set('main.VALUE', 'via-link');
    ok($through_link->save(), 'existing symbolic configuration path remains supported');
    ok(-l $alias, 'saving through a symbolic config preserves the link');
    is(Mediabot::Conf->new({}, $path)->get('main.VALUE'), 'via-link', 'complete target is replaced through the link');
    my $other = "$root/symlink-config/other.conf"; put_config($other, $initial);
    unlink $alias; symlink 'other.conf', $alias or die 'fixture retarget';
    $through_link->set('main.VALUE', 'misdirected');
    ok(!eval { $through_link->save(); 1 }, 'retargeting a loaded symlink requires explicit reload');
    is(read_config($other), $initial, 'symlink retarget cannot redirect a save to another config');
    is(Mediabot::Conf->new({}, $path)->get('main.VALUE'), 'via-link', 'previous target is retained too');
}

{
    my ($path, $conf) = fixture('symlink-lock');
    my $other = "$root/symlink-lock/private-data"; put_config($other, 'keep');
    symlink $other, "$path.lock" or die 'fixture lock symlink';
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'symbolic lock is refused');
    is(read_config($path), $initial, 'symbolic lock refusal preserves active configuration');
    is(read_config($other), 'keep', 'symbolic lock target is never changed');
}

{
    my ($path, $conf) = fixture('hardlink-config');
    my $alias = "$root/hardlink-config/alias.conf"; link $path, $alias or die 'fixture hardlink';
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'multiple hardlinks require explicit operator resolution');
    is(read_config($alias), $initial, 'save never silently splits a hardlinked configuration');
    is(read_config($path), $initial, 'hardlink refusal preserves both paths');
}

{
    my ($path, $conf) = fixture('missing-file');
    unlink $path or die 'fixture unlink';
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'deleted loaded configuration is not silently recreated');
    ok(!-e $path, 'deleted path stays absent after save refusal');
}

{
    my ($path, $conf) = fixture('killed-writer');
    pipe(my $read, my $write) or die 'fixture crash pipe';
    my $pid = fork(); die 'fixture crash fork' unless defined $pid;
    if (!$pid) {
        close $read; alarm 5;
        no warnings 'redefine';
        local *Config::Simple::write = sub {
            my ($cfg, $target) = @_;
            put_config($target, "[main]\nVALUE=interrupted\n");
            syswrite($write, 'x', 1) == 1 or POSIX::_exit(9);
            POSIX::pause(); POSIX::_exit(9);
        };
        $conf->set('main.VALUE', 'bot');
        eval { $conf->save() }; POSIX::_exit(9);
    }
    close $write;
    my $ready; is(sysread($read, $ready, 1), 1, 'writer reaches incomplete serialization before crash');
    close $read; kill 'KILL', $pid; waitpid($pid, 0);
    is($? & 127, 9, 'real writer is interrupted by SIGKILL');
    is(read_config($path), $initial, 'abrupt process death leaves active configuration complete');
    my @orphans = glob("$root/killed-writer/.mediabot-conf-*");
    is(scalar @orphans, 1, 'untrappable death can leave one identifiable temporary file');
    is((stat($orphans[0]))[2] & 0777, 0600, 'interrupted temporary content remains private');
    unlink @orphans;
    $conf->set('main.VALUE', 'recovered');
    ok($conf->save(), 'kernel releases the writer lock after process death');
}

{
    my ($path, $conf) = fixture('umask');
    my $old = umask 0077;
    $conf->set('main.VALUE', 'private');
    my $ok = eval { $conf->save(); 1 };
    my $current = umask $old;
    ok($ok, 'save works with a restrictive caller umask');
    is($current, 0077, 'save never changes the caller umask');
    is((stat($path))[2] & 0777, 0600, 'restricted configuration remains private');
}

{
    my ($path, $conf) = fixture('mode-change');
    chmod 0640, $path or die 'fixture operator mode';
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'operator permission change invalidates a stale writer');
    is((stat($path))[2] & 0777, 0640, 'save refusal preserves the operator-selected mode');
    is(read_config($path), $initial, 'permission conflict keeps original values');
    $conf->reload(); $conf->set('main.VALUE', 'reapplied');
    ok($conf->save(), 'explicit reload adopts the new mode');
    is((stat($path))[2] & 0777, 0640, 'newly acknowledged mode survives publication');
}

{
    my ($path, $conf) = fixture('hardlink-lock');
    my $other = "$root/hardlink-lock/other"; put_config($other, 'keep');
    chmod 0640, $other or die 'fixture hardlink mode';
    link $other, "$path.lock" or die 'fixture hardlink lock';
    $conf->set('main.VALUE', 'bot');
    ok(!eval { $conf->save(); 1 }, 'multiply-linked lock files are refused before metadata changes');
    is(read_config($other), 'keep', 'hardlinked lock target content is retained');
    is((stat($other))[2] & 0777, 0640, 'hardlinked lock target mode is retained');
}

{
    my ($path, $conf) = fixture('forked-writers');
    pipe(my $read, my $write) or die 'fixture pipe';
    my @pids;
    for my $name (qw(one two)) {
        my $pid = fork(); die 'fixture fork' unless defined $pid;
        if (!$pid) {
            close $write; alarm 5;
            my $go; sysread($read, $go, 1) == 1 or POSIX::_exit(9);
            $conf->set('main.VALUE', $name);
            my $ok = eval { $conf->save(); 1 };
            POSIX::_exit($ok ? 0 : 2);
        }
        push @pids, $pid;
    }
    close $read; print {$write} 'xx'; close $write;
    my @status;
    for my $pid (@pids) { waitpid($pid, 0); push @status, $?; }
    is_deeply([sort {$a<=>$b} @status], [0, 2 << 8], 'real concurrent writers have one winner and one explicit refusal');
    my $readback = Mediabot::Conf->new({}, $path);
    like($readback->get('main.VALUE'), qr/\A(?:one|two)\z/, 'winner is a complete parseable configuration');
    is($readback->get('main.KEEP'), 'yes', 'concurrent publication retains unrelated keys');
    ok(no_temps($path), 'concurrent publication leaves no partial temporary files');
}

ok(!defined(Mediabot::Conf->new({'main.VALUE'=>'memory'})->save()), 'memory-only save retains its historical no-op contract');
done_testing;
