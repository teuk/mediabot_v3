#!/usr/bin/env perl

# mb378-R1: atomic INI generation/merge/audit engine; never evals config.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use POSIX qw(strftime);

my %opt = (
    mode   => 'merge',
    strict => 0,
    quiet  => 0,
);

GetOptions(
    'sample=s'     => \$opt{sample},
    'config=s'     => \$opt{config},
    'mode=s'       => \$opt{mode},
    'overlay=s'    => \$opt{overlay},
    'defaults=s'   => \$opt{defaults},
    'backup-dir=s' => \$opt{backup_dir},
    'force!'       => \$opt{force},
    'strict!'      => \$opt{strict},
    'quiet!'       => \$opt{quiet},
    'get=s'        => \$opt{get},
    'help'         => \$opt{help},
) or die usage();

if ($opt{help}) {
    print usage();
    exit 0;
}

die usage() unless defined $opt{config} && length $opt{config};

if (defined $opt{get}) {
    my $parsed = parse_ini_file($opt{config});
    my $key = normalize_full_key($opt{get});
    exit 1 unless exists $parsed->{values}{$key};
    print $parsed->{values}{$key}, "\n";
    exit 0;
}

if ($opt{mode} eq 'audit') {
    die "--sample is required for audit mode\n" unless defined $opt{sample};
    exit audit_config(\%opt);
}

die "Unsupported mode '$opt{mode}' (expected fresh, merge, or audit)\n"
    unless $opt{mode} eq 'fresh' || $opt{mode} eq 'merge';
die "--sample is required\n" unless defined $opt{sample} && -f $opt{sample};

my $existing = {
    values       => {},
    section_keys => {},
    sections     => [],
    duplicates   => [],
};

if (-e $opt{config}) {
    die "Configuration already exists: $opt{config} (use --force or --mode merge)\n"
        if $opt{mode} eq 'fresh' && !$opt{force};
    $existing = parse_ini_file($opt{config});
}
elsif ($opt{mode} eq 'merge') {
    die "Configuration file does not exist: $opt{config}\n";
}

my $overlay  = defined $opt{overlay}  ? parse_overlay_file($opt{overlay})  : {};
my $defaults = defined $opt{defaults} ? parse_overlay_file($opt{defaults}) : {};

my %effective = %{ $existing->{values} };
for my $key (keys %$defaults) {
    $effective{$key} = $defaults->{$key} unless exists $effective{$key};
}
for my $key (keys %$overlay) {
    $effective{$key} = $overlay->{$key};
}

my $rendered = render_from_sample(
    sample   => $opt{sample},
    values   => \%effective,
    existing => $existing,
);

my $backup;
if (-e $opt{config}) {
    $backup = backup_config($opt{config}, $opt{backup_dir});
}

write_atomic($opt{config}, $rendered);

unless ($opt{quiet}) {
    print "Configuration written atomically: $opt{config}\n";
    print "Backup created: $backup\n" if defined $backup;
    if (@{ $existing->{duplicates} || [] }) {
        print "Duplicate active keys normalized (last value kept):\n";
        print "  $_\n" for @{ $existing->{duplicates} };
    }
}

exit 0;

sub usage {
    return <<'USAGE';
Usage:
  install/configure_config.pl --sample mediabot.sample.conf --config mediabot.conf --mode fresh [options]
  install/configure_config.pl --sample mediabot.sample.conf --config mediabot.conf --mode merge [options]
  install/configure_config.pl --sample mediabot.sample.conf --config mediabot.conf --mode audit [--strict]
  install/configure_config.pl --config mediabot.conf --get section.KEY

Options:
  --overlay <file>       Forced values (section.KEY=value, one per line)
  --defaults <file>      Values applied only when the key is missing
  --backup-dir <dir>     Directory for timestamped backups
  --force                Allow fresh mode to replace an existing file
  --strict               Audit exits non-zero on missing keys, duplicates, or unsafe eval
  --quiet                Reduce normal output

The writer never evaluates configuration values. It preserves known values,
adds all active keys from mediabot.sample.conf, keeps optional documented keys
commented unless already configured, preserves custom keys/sections, writes via
an atomic rename, and stores the resulting file with mode 0600.
USAGE
}

sub normalize_full_key {
    my ($key) = @_;
    $key //= '';
    $key =~ s/^\s+|\s+$//g;
    die "Invalid key '$key' (expected section.KEY)\n"
        unless $key =~ /\A([A-Za-z0-9_.-]+)\.([A-Za-z0-9_.-]+)\z/;
    return lc($1) . '.' . $2;
}

sub parse_overlay_file {
    my ($file) = @_;
    die "Overlay file not found: $file\n" unless -f $file;
    open my $fh, '<', $file or die "Cannot read overlay $file: $!\n";
    my %values;
    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;
        chomp $line;
        $line =~ s/\r\z//;
        next if $line =~ /^\s*\z/ || $line =~ /^\s*[#;]/;
        die "Invalid overlay line $file:$line_no\n" unless $line =~ /^([^=]+)=(.*)\z/s;
        my ($key, $value) = ($1, $2);
        $key = normalize_full_key($key);
        die "NUL/newline not allowed in overlay value for $key\n" if $value =~ /[\x00\r\n]/;
        $values{$key} = $value;
    }
    close $fh;
    return \%values;
}

sub parse_ini_file {
    my ($file) = @_;
    die "Configuration file not found: $file\n" unless -f $file;
    open my $fh, '<', $file or die "Cannot read $file: $!\n";

    my (%values, %section_keys, %seen, @sections, @duplicates);
    my $section = '';
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r\z//;
        next if $line =~ /^\s*\z/ || $line =~ /^\s*[#;]/;
        if ($line =~ /^\s*\[([^\]]+)\]\s*\z/) {
            $section = lc trim($1);
            push @sections, $section unless grep { $_ eq $section } @sections;
            next;
        }
        next unless length $section;
        next unless $line =~ /^\s*([^=]+?)\s*=\s*(.*)\z/s;
        my ($key, $value) = (trim($1), $2);
        next unless $key =~ /\A[A-Za-z0-9_.-]+\z/;
        my $full = "$section.$key";
        push @duplicates, $full if $seen{$full}++;
        $values{$full} = $value;
        $section_keys{$section}{$key} = 1;
    }
    close $fh;

    return {
        values       => \%values,
        section_keys => \%section_keys,
        sections     => \@sections,
        duplicates   => \@duplicates,
    };
}

sub render_from_sample {
    my (%args) = @_;
    my $sample   = $args{sample};
    my $values   = $args{values};
    my $existing = $args{existing};

    open my $fh, '<', $sample or die "Cannot read sample $sample: $!\n";
    my @lines = <$fh>;
    close $fh;

    my %sample_active_keys;
    {
        my $scan_section = '';
        for my $scan_line (@lines) {
            if ($scan_line =~ /^\s*\[([^\]]+)\]\s*$/) {
                $scan_section = lc trim($1);
                next;
            }
            if (length $scan_section && $scan_line =~ /^\s*([A-Za-z0-9_.-]+)\s*=/) {
                $sample_active_keys{"$scan_section.$1"} = 1;
            }
        }
    }

    my @out;
    my $section = '';
    my %consumed;
    my %active_sections;

    my $flush_section_extras = sub {
        my ($sec) = @_;
        return unless length $sec;
        my @extra = sort grep {
            index($_, "$sec.") == 0 && !$consumed{$_}
        } keys %$values;
        return unless @extra;
        push @out, "\n# Existing/custom settings preserved by ./configure\n";
        for my $full (@extra) {
            my $key = substr($full, length($sec) + 1);
            push @out, "$key=$values->{$full}\n";
            $consumed{$full} = 1;
        }
    };

    for my $line (@lines) {
        if ($line =~ /^\s*\[([^\]]+)\]\s*$/) {
            $flush_section_extras->($section);
            $section = lc trim($1);
            $active_sections{$section} = 1;
            push @out, $line;
            next;
        }

        if (length $section && $line =~ /^(\s*)([A-Za-z0-9_.-]+)(\s*=\s*)(.*?)(\r?\n)?\z/s) {
            my ($indent, $key, $sep, $sample_value, $eol) = ($1, $2, $3, $4, $5 // "\n");
            my $full = "$section.$key";
            if (exists $values->{$full}) {
                push @out, "$indent$key=$values->{$full}$eol";
                $consumed{$full} = 1;
            }
            else {
                push @out, $line;
            }
            next;
        }

        # Optional single-key examples (for example DCC_PUBLIC_IP or a cookies
        # file) remain commented on a fresh install. If an existing config has
        # the key, merge activates it in the canonical location.
        if (length $section && $line =~ /^(\s*)#\s*([A-Z][A-Z0-9_.-]+)\s*=([^\r\n]*)(\r?\n)?\z/) {
            my ($indent, $key, $eol) = ($1, $2, $4 // "\n");
            my $full = "$section.$key";
            if (!$sample_active_keys{$full} && exists $values->{$full}) {
                push @out, "$indent$key=$values->{$full}$eol";
                $consumed{$full} = 1;
            }
            else {
                push @out, $line;
            }
            next;
        }

        push @out, $line;
    }

    $flush_section_extras->($section);

    my %remaining_by_section;
    for my $full (sort keys %$values) {
        next if $consumed{$full};
        my ($sec, $key) = split /\./, $full, 2;
        push @{ $remaining_by_section{$sec} }, [ $key, $values->{$full} ];
    }

    if (%remaining_by_section) {
        push @out, "\n# -----------------------------------------------------------------------------\n";
        push @out, "# Custom sections preserved from the previous configuration\n";
        push @out, "# -----------------------------------------------------------------------------\n";
        for my $sec (sort keys %remaining_by_section) {
            push @out, "\n[$sec]\n";
            for my $pair (@{ $remaining_by_section{$sec} }) {
                push @out, "$pair->[0]=$pair->[1]\n";
            }
        }
    }

    my $text = join('', @out);
    $text .= "\n" unless $text =~ /\n\z/;
    return $text;
}

sub backup_config {
    my ($config, $backup_dir) = @_;
    $backup_dir = dirname($config) unless defined $backup_dir && length $backup_dir;
    make_path($backup_dir, { mode => 0750 }) unless -d $backup_dir;
    my $stamp = strftime('%Y%m%d_%H%M%S', localtime);
    my $dest = File::Spec->catfile($backup_dir, basename($config) . ".configure_${stamp}.bak");
    my $n = 1;
    while (-e $dest) {
        $dest = File::Spec->catfile($backup_dir, basename($config) . ".configure_${stamp}_$n.bak");
        $n++;
    }
    copy($config, $dest) or die "Cannot create backup $dest: $!\n";
    chmod 0600, $dest or die "Cannot chmod backup $dest: $!\n";
    return $dest;
}

sub write_atomic {
    my ($config, $content) = @_;
    my $dir = dirname($config);
    make_path($dir, { mode => 0750 }) unless -d $dir;

    my ($uid, $gid) = (-1, -1);
    if (-e $config) {
        my @st = stat($config);
        ($uid, $gid) = @st[4,5] if @st;
    }

    my ($fh, $tmp) = tempfile('.mediabot.conf.XXXXXX', DIR => $dir, UNLINK => 0);
    binmode $fh, ':raw';
    chmod 0600, $tmp or die "Cannot chmod temporary config $tmp: $!\n";
    print {$fh} $content or die "Cannot write temporary config $tmp: $!\n";
    close $fh or die "Cannot close temporary config $tmp: $!\n";

    if ($uid >= 0 && $gid >= 0 && $> == 0) {
        chown $uid, $gid, $tmp or die "Cannot preserve owner on $tmp: $!\n";
    }

    rename $tmp, $config or do {
        unlink $tmp;
        die "Cannot replace $config atomically: $!\n";
    };
    chmod 0600, $config or die "Cannot chmod $config: $!\n";
}

sub audit_config {
    my ($opt) = @_;
    my $config = parse_ini_file($opt->{config});
    my $sample = parse_ini_file($opt->{sample});

    my @missing = sort grep { !exists $config->{values}{$_} } keys %{ $sample->{values} };
    my @unknown = sort grep { !exists $sample->{values}{$_} } keys %{ $config->{values} };
    my @duplicates = @{ $config->{duplicates} || [] };
    my @unsafe;

    my $eval_key = 'main.PARTYLINE_EVAL_ENABLED';
    if (exists $config->{values}{$eval_key}
        && trim($config->{values}{$eval_key}) !~ /\A(?:0|no|false|off)?\z/i) {
        push @unsafe, "$eval_key=$config->{values}{$eval_key}";
    }

    my @st = stat($opt->{config});
    if (@st && ($st[2] & 0077)) {
        push @unsafe, sprintf('permissions=%04o (recommended 0600)', $st[2] & 07777);
    }

    unless ($opt->{quiet}) {
        print "Configuration audit: $opt->{config}\n";
        print "  active sample keys : ", scalar(keys %{ $sample->{values} }), "\n";
        print "  configured keys    : ", scalar(keys %{ $config->{values} }), "\n";
        print "  missing defaults   : ", scalar(@missing), "\n";
        print "  custom/extra keys  : ", scalar(@unknown), "\n";
        print "  duplicate keys     : ", scalar(@duplicates), "\n";
        print "  safety warnings    : ", scalar(@unsafe), "\n";
        print "\nMissing active sample keys:\n  ", join("\n  ", @missing), "\n" if @missing;
        print "\nCustom/extra keys preserved:\n  ", join("\n  ", @unknown), "\n" if @unknown;
        print "\nDuplicate keys:\n  ", join("\n  ", @duplicates), "\n" if @duplicates;
        print "\nSafety warnings:\n  ", join("\n  ", @unsafe), "\n" if @unsafe;
    }

    return 1 if $opt->{strict} && (@missing || @duplicates || @unsafe);
    return 0;
}

sub trim {
    my ($s) = @_;
    $s //= '';
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
