package MB1241LocalVersion;
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw(abs_path);
use JSON::PP ();
use ColdProbeBatch ();
sub check {
    my ($assert, $baseline) = @_;
    my @modes = $baseline ? qw(helpers symlink) : qw(helpers symlink local local_first helpers_first remote);
    my @code = map { "require MB1241LocalVersion; MB1241LocalVersion::probe('$_');" } @modes;
    my $results = ColdProbeBatch::run_perl_probes(\@code, warnings=>1);
    for my $i (0..$#modes) {
        my $r=$results->[$i];
        my $data=eval {JSON::PP::decode_json($r->{stdout})};
        $assert->($r->{status}==0 && $r->{stderr} eq '' && ref($data) eq 'ARRAY',
            "MB1241 $modes[$i] native probe completes without warnings: $r->{stderr}");
        next unless ref($data) eq 'ARRAY';
        $assert->($_->[0], "MB1241 $modes[$i] $_->[1]") for @$data;
    }
}
sub probe {
    my ($mode)=@_;
    my $root=abs_path('.');
    @INC=map {ref($_)?$_:abs_path($_)//$_} @INC;
    my $tree=tempdir(CLEANUP=>1);
    make_path("$tree/Mediabot/Version");
    for my $name (qw(Helpers.pm Version/Format.pm Version/Remote.pm Version/Local.pm)) {
        copy("$root/Mediabot/$name", "$tree/Mediabot/$name") or die $!
            if -f "$root/Mediabot/$name";
    }
    my $path="$tree/VERSION";
    my $write=sub { open my $fh,'>', $path or die $!; print $fh $_[0]; close $fh or die $! };
    $write->(" 3.8dev-20261111_220000 \nignored second line\n");
    unshift @INC,$tree;
    if ($mode eq 'symlink') {
        my $alias="$tree/alias";make_path("$alias/Mediabot");
        symlink("$tree/Mediabot/Helpers.pm","$alias/Mediabot/Helpers.pm") or die $!;
        open my $f,'>',"$alias/VERSION" or die $!;print $f 'wrong alias version';close $f;
        unshift @INC,$alias;
    }
    my @checks;my $check=sub { push @checks, [$_[0]?1:0,$_[1]] };
    if ($mode eq 'local_first') { require Mediabot::Version::Local }
    if ($mode =~ /helpers|symlink|local_first/) { require Mediabot::Helpers }
    if ($mode eq 'helpers_first' || $mode eq 'local') { require Mediabot::Version::Local }
    if ($mode eq 'remote') { require Mediabot::Version::Remote }
    if ($mode eq 'local') {
        $check->(!grep({exists $INC{$_}} qw(Mediabot/Helpers.pm HTTP/Tiny.pm DBI.pm Mediabot/AsyncWorker.pm)),
            'local component loads without Helpers, network, DB or worker');
    }
    my $foreign=tempdir(CLEANUP=>1);
    chdir $foreign or die $!;
    open my $decoy,'>','VERSION' or die $!;print $decoy 'wrong cwd version';close $decoy;
    my $uses_helpers=$mode !~ /^(local|remote)$/;
    my $get = $uses_helpers ? \&Mediabot::Helpers::getLocalVersion
        : $mode eq 'remote' ? \&Mediabot::Version::Remote::getLocalVersion
        : \&Mediabot::Version::Local::getLocalVersion;
    my $cached = $uses_helpers ? \&Mediabot::Helpers::_cached_local_version
        : $mode eq 'remote' ? \&Mediabot::Version::Remote::_cached_local_version
        : \&Mediabot::Version::Local::cached;
    my $logger=bless {lines=>[]},'MB1241LocalVersion::Log';
    my $bot={main_prog_version=>'3.7',logger=>$logger};
    for my $row ([" 3.8dev-20261111_220000 \nignored\n",'3.8dev-20261111_220000'],
            ["  release-label  \n",'release-label'],["\n",'3.7'],['Undefined','3.7'],['','3.7'],[undef,'3.7']) {
        defined($row->[0]) ? $write->($row->[0]) : unlink($path);
        $bot->{main_prog_version}='3.7';$logger->{lines}=[];
        my $got=$get->($bot);
        $check->($got eq $row->[1], 'first-line/invalid/missing read uses exact source and fallback');
        $check->($bot->{main_prog_version} eq $row->[1], 'cache retains usable identity');
        $check->($logger->{lines}[0][0]==1 && $logger->{lines}[0][1] eq "Reading local version from $path...",
            'start diagnostic retains exact anchored path');
        $check->(defined($row->[0]) ? @{$logger->{lines}}==1
            : @{$logger->{lines}}==2 && $logger->{lines}[1][1]=~/\AUnable to read local VERSION file /,
            'missing-file diagnostic remains distinct from unusable contents');
    }
    $bot->{main_prog_version}=' Undefined ';$logger->{lines}=[];
    $check->($get->($bot) eq 'Undefined' && $bot->{main_prog_version} eq ' Undefined ',
        'no usable identity leaves cache unchanged');
    $logger->{lines}=[];$bot->{main_prog_version}=' 3.7 ';
    $check->($cached->($bot) eq '3.7' && !@{$logger->{lines}} && !-e $path,
        'cache access neither reads VERSION nor logs');
    $check->($cached->(undef) eq 'Undefined' && $cached->('not an object') eq 'Undefined',
        'cache accessor preserves non-reference contract');
    $write->('3.8');
    my $exception=bless {},'MB1241LocalVersion::Error';$logger->{error}=$exception;
    eval {$get->($bot)};my $error=$@;
    $check->(ref($error) && $error==$exception,'logger exception identity survives');
    delete $logger->{error};
    if ($uses_helpers) {
        no warnings 'redefine';
        my $seen;
        local *Mediabot::Helpers::_read_local_version=sub {$seen=$_[0];' hook-version '};
        $check->($get->($bot) eq 'hook-version' && $seen==$bot,'legacy reader override remains call-time');
        {
            local *Mediabot::Helpers::_usable_local_version=sub {'normalized-hook'};
            $check->($get->($bot) eq 'normalized-hook' && $cached->($bot) eq 'normalized-hook',
                'legacy normalizer override reaches read result and cache');
        }
    }
    if ($uses_helpers) {
        no warnings 'redefine';
        local *Mediabot::Helpers::_read_local_version=sub {'before-log'};
        $logger->{hook}=sub { *Mediabot::Helpers::_read_local_version=sub {'after-log'} };
        $check->($get->($bot) eq 'after-log', 'reader override installed by logger is observed');
        delete $logger->{hook};
    }
    if ($mode eq 'remote') {
        $check->(!exists $INC{'Mediabot/Helpers.pm'}, 'remote local fallback never imports Helpers');
        no warnings 'redefine';
        local *Mediabot::Helpers::getLocalVersion=sub {'override-local'};
        local *Mediabot::Helpers::_cached_local_version=sub {'override-cache'};
        $check->($get->($bot) eq 'override-local' && $cached->($bot) eq 'override-cache',
            'remote preserves optional legacy overrides');
    }
    chdir $root or die $!;
    print JSON::PP->new->encode(\@checks);
}
package MB1241LocalVersion::Log;
sub log { my ($s,@args)=@_;die $s->{error} if $s->{error}; $s->{hook}->() if $s->{hook}; push @{$s->{lines}},\@args;1 }
1;
