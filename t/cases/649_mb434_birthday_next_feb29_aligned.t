# t/cases/649_mb434_birthday_next_feb29_aligned.t
# =============================================================================
# mb434 — "!birthday next" est aligné sur l'annonce automatique pour les
# anniversaires du 29 février.
#
# mb433 a fait observer les anniversaires 02-29 le 28 février des années non
# bissextiles (côté annonce). Mais _birthday_days_ahead (base de
# "!birthday next") sautait encore les années non bissextiles pour un 29/02 et
# renvoyait le prochain 29 février réel (jusqu'à ~4 ans plus tard) : la
# commande annonçait une date bien plus lointaine que le jour où la personne
# serait réellement fêtée. mb434 aligne le helper sur l'observance mb433.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Time::Local qw(timegm timelocal);

sub _slurp_649 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Reproduction fidèle de la logique ------------------------------
    my $valid = sub {
        my ($y,$m,$d)=@_;
        return 0 unless $m>=1&&$m<=12&&$d>=1&&$d<=31;
        my @dim=(0,31,($y%4==0&&($y%100!=0||$y%400==0))?29:28,31,30,31,30,31,31,30,31,30,31);
        return 0 if $d>$dim[$m]; 1;
    };
    my $ahead = sub {
        my ($month,$day,$now)=@_;
        my @t=localtime($now); my $year=$t[5]+1900;
        my $te=timelocal(0,0,12,$t[3],$t[4],$year);
        for my $o (0..4){
            my $cy=$year+$o; my ($om,$od)=($month,$day);
            if($month==2&&$day==29){
                my $l=($cy%4==0&&($cy%100!=0||$cy%400==0))?1:0;
                ($om,$od)=(2,28) unless $l;
            }
            next unless $valid->($cy,$om,$od);
            my $ce=timelocal(0,0,12,$od,$om-1,$cy);
            next if $ce<$te;
            return int(($ce-$te)/86400+0.5);
        }
        return undef;
    };

    # Depuis le 03/07/2026, un 29/02 est observé le 28/02/2027 (non bissextile).
    my $mid = timelocal(0,0,12,3,6,2026);
    my $exp_2027 = int((timelocal(0,0,12,28,1,2027) - $mid)/86400 + 0.5);
    $assert->is($ahead->(2,29,$mid), $exp_2027, '29/02 -> 28/02/2027 (observé), pas 2028');

    # Une année bissextile en vue : depuis le 01/01/2028 (bissextile), 29/02 réel.
    my $early2028 = timelocal(0,0,12,1,0,2028);
    my $exp_feb29_2028 = int((timelocal(0,0,12,29,1,2028) - $early2028)/86400 + 0.5);
    $assert->is($ahead->(2,29,$early2028), $exp_feb29_2028, 'année bissextile: 29/02 réel');

    # Anniversaire normal : inchangé.
    my $t = timelocal(0,0,12,3,6,2026);
    $assert->is($ahead->(7,4,$t), 1, 'anniv normal (04/07) inchangé -> 1');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_649(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub _birthday_days_ahead \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/if \(\$month == 2 && \$day == 29\)/, 'cas 29 février traité');
    $assert->like($code, qr/\(\$obs_month, \$obs_day\) = \(2, 28\) unless \$leap;/,
        'observance 28/02 les années non bissextiles');
    $assert->like($code, qr/_birthday_valid_date\(\$candidate_year, \$obs_month, \$obs_day\)/,
        'validation sur la date observée');
    $assert->like($src, qr/mb434-R1/, 'tag mb434-R1');
};
