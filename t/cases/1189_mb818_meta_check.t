use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use IPC::Open3;
use Symbol qw(gensym);
my $dir=tempdir(CLEANUP=>1);my $file="$dir/bot.conf";
open my $fh,'>',$file or die $!;print {$fh} <<'CONF';
[meta_ai]
ENABLED=0
CHANNELS=#pilot
[openai]
API_KEY=YOUR_OPENAI_TEST_KEY
[anthropic]
API_KEY=YOUR_CLAUDE_TEST_KEY
[gemini]
API_KEY=YOUR_GEMINI_TEST_KEY
CONF
close $fh;chmod 0600,$file;
sub run_check {
    my (@args)=@_;my $err=gensym;my $pid=open3(undef,my $out,$err,$^X,'tools/meta_ai_check.pl',@args);
    local $/;my $text=<$out>//'';my $error=<$err>//'';waitpid($pid,0);return ($?>>8,$text.$error);
}
my ($code,$text)=run_check('--conf',$file);
is($code,0,'offline checker accepts private configured pilot');
like($text,qr/model=gpt-6\.1-sol/,'checker reports new OpenAI model');
like($text,qr/Mode: disabled/,'check does not activate the mode');
like($text,qr/Offline check.*Nothing deployed/s,'offline result distinguishes validation from deployment');
unlike($text,qr/YOUR_(?:OPENAI|CLAUDE|GEMINI)_TEST_KEY/,'no private credential is printed');
chmod 0644,$file;($code,$text)=run_check('--conf',$file);
ok($code!=0,'public-readable private configuration is rejected');
like($text,qr/mode 0600/,'permission failure is actionable without secret content');
($code,$text)=run_check('--help');is($code,0,'help needs no private configuration');
like($text,qr/paid test/,'live probing is explicitly described as paid');
done_testing;
