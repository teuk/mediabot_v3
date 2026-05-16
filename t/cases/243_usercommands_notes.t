# t/cases/243_usercommands_notes.t
# Verify mbNote_ctx and mbNotes_ctx structure.
use strict; use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _slurp { open my $fh,'<:encoding(UTF-8)',$_[0] or die $!; local $/; <$fh> }
sub _sub { my($s,$n)=@_; my $re=qr/^[ \t]*sub[ \t]+\Q$n\E\b[^{]*\{/m;
    return undef unless $s=~/$re/g; my($st,$p,$d)=($-[0],pos($s),1);
    while($p<length($s)){my $c=substr($s,$p,1);$d++ if $c eq '{';$d-- if $c eq '}';
    return substr($s,$st,$p+1-$st) if $d==0; $p++} undef }
return sub {
    my ($assert) = @_;
    my $src = _slurp(File::Spec->catfile('.','Mediabot','UserCommands.pm'));

    my $note = _sub($src, 'mbNote_ctx');
    $assert->ok(defined $note, 'mbNote_ctx sub found');
    $assert->like($note // '', qr/_notes/,
        'mbNote_ctx stores in _notes hash');
    $assert->like($note // '', qr/10/,
        'mbNote_ctx caps at 10 notes');
    $assert->like($note // '', qr/C4\/fix.*ordinal|ordinal/,
        'mbNote_ctx uses ordinal ID (C4/fix)');

    my $notes = _sub($src, 'mbNotes_ctx');
    $assert->ok(defined $notes, 'mbNotes_ctx sub found');
    $assert->like($notes // '', qr/del|delete/i,
        'mbNotes_ctx supports del subcommand');
    $assert->like($notes // '', qr/_notes/,
        'mbNotes_ctx reads from _notes hash');

    my $mm = _slurp(File::Spec->catfile('.','Mediabot','Mediabot.pm'));
    $assert->like($mm, qr/note\|/,  'Mediabot.pm has help entry for !note');
    $assert->like($mm, qr/notes\|/, 'Mediabot.pm has help entry for !notes');
};
