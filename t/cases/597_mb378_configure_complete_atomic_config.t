use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use File::Temp qw(tempdir);

sub _slurp_mb378_config_engine {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _active_ini_mb378_config_engine {
    my ($src) = @_;
    my (%v, %dups, $section);
    $section = '';
    for my $line (split /\n/, $src) {
        next if $line =~ /^\s*(?:[#;]|\z)/;
        if ($line =~ /^\s*\[([^\]]+)\]\s*$/) {
            $section = lc $1;
            next;
        }
        next unless length $section && $line =~ /^\s*([^=]+?)\s*=\s*(.*)$/;
        my ($key, $value) = ($1, $2);
        $key =~ s/^\s+|\s+$//g;
        my $full = "$section.$key";
        $dups{$full}++ if exists $v{$full};
        $v{$full} = $value;
    }
    return (\%v, \%dups);
}

return sub {
    my ($assert) = @_;

    my $root   = File::Spec->catdir('.', '');
    my $helper = File::Spec->catfile('.', 'install', 'configure_config.pl');
    my $sample = File::Spec->catfile('.', 'mediabot.sample.conf');
    my $tmp    = tempdir(CLEANUP => 1);
    my $config = File::Spec->catfile($tmp, 'mediabot.conf');
    my $defaults = File::Spec->catfile($tmp, 'defaults');
    my $overlay  = File::Spec->catfile($tmp, 'overlay');

    open my $dfh, '>', $defaults or die $!;
    print {$dfh} "main.MAIN_PID_FILE=$tmp/mediabot.pid\n";
    print {$dfh} "main.MAIN_LOG_FILE=$tmp/mediabot.log\n";
    close $dfh;

    open my $ofh, '>', $overlay or die $!;
    print {$ofh} "main.MAIN_PROG_CMD_CHAR=?\n";
    print {$ofh} "main.PARTYLINE_EVAL_ENABLED=0\n";
    close $ofh;

    my $fresh_rc = system($^X, $helper,
        '--sample', $sample,
        '--config', $config,
        '--mode', 'fresh',
        '--defaults', $defaults,
        '--overlay', $overlay,
        '--quiet');
    $assert->is($fresh_rc, 0, 'fresh complete config generation succeeds');
    $assert->ok(-f $config, 'fresh config exists');

    my $sample_src = _slurp_mb378_config_engine($sample);
    my $config_src = _slurp_mb378_config_engine($config);
    my ($sample_values) = _active_ini_mb378_config_engine($sample_src);
    my ($config_values, $fresh_dups) = _active_ini_mb378_config_engine($config_src);

    my @missing = sort grep { !exists $config_values->{$_} } keys %$sample_values;
    $assert->is(join(',', @missing), '', 'fresh config contains every active sample key');
    $assert->is(join(',', sort keys %$fresh_dups), '', 'fresh config has no duplicate active key');
    $assert->is($config_values->{'main.MAIN_PROG_CMD_CHAR'}, '?', 'overlay replaces command prefix');
    $assert->is($config_values->{'main.PARTYLINE_EVAL_ENABLED'}, '0', 'dangerous eval remains disabled');
    $assert->is($config_values->{'main.MAIN_PID_FILE'}, "$tmp/mediabot.pid", 'dynamic default path applied');
    $assert->is((stat($config))[2] & 0777, 0600, 'generated config mode is 0600');

    open my $append, '>>', $config or die $!;
    print {$append} "\n[main]\nMAIN_PROG_DEBUG=3\nCUSTOM_VALUE=preserved\n";
    print {$append} "\n[custom]\nFOO=bar\n";
    close $append;

    my $backup_dir = File::Spec->catdir($tmp, 'backups');
    my $merge_rc = system($^X, $helper,
        '--sample', $sample,
        '--config', $config,
        '--mode', 'merge',
        '--backup-dir', $backup_dir,
        '--quiet');
    $assert->is($merge_rc, 0, 'existing config merge succeeds');

    my $merged_src = _slurp_mb378_config_engine($config);
    my ($merged, $merged_dups) = _active_ini_mb378_config_engine($merged_src);
    $assert->is($merged->{'main.MAIN_PROG_DEBUG'}, '3', 'existing value wins over sample default');
    $assert->is($merged->{'main.CUSTOM_VALUE'}, 'preserved', 'custom key is preserved');
    $assert->is($merged->{'custom.FOO'}, 'bar', 'custom section is preserved');
    $assert->is(join(',', sort keys %$merged_dups), '', 'merge normalizes duplicate active keys');

    opendir my $dh, $backup_dir or die $!;
    my @backups = grep { /\.configure_.*\.bak$/ } readdir $dh;
    closedir $dh;
    $assert->is(scalar @backups, 1, 'merge creates one timestamped backup');
};
