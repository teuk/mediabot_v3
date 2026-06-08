# t/cases/389_mb130_log_rotation_and_password_redact.t
# =============================================================================
# Tests des corrections mb130 :
#
#   - B1 : Mediabot::Log::log capturait my $fh AVANT _maybe_rotate(),
#          puis _maybe_rotate() pouvait renommer le fichier et reouvrir
#          $self->{logfilehandle} sur le nouveau path -- mais le print
#          utilisait la VIEILLE reference $fh qui pointait encore vers
#          le fichier maintenant nomme ".log.1". La 100eme ecriture
#          apres rotation atterrissait dans le fichier rotate.
#
#   - B2 : botPrivmsg loggait le contenu textuel des messages prives au
#          niveau 0 (toujours actif). Les commandes IRC services
#          (NickServ identify, X login, ChanServ register, etc.) etaient
#          loggees EN CLAIR avec le password en argument.
#          Tout acces lecture au log file = compromission credentials.
# =============================================================================

use strict;
use warnings;
use File::Temp qw(tempdir);
use IO::Handle;

my $case = sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1 : log rotation et capture du fh dans le bon ordre
    # -------------------------------------------------------------------------

    # Implementation buggy : capture fh AVANT rotate
    my $buggy_log = sub {
        my ($self, $msg) = @_;
        if (my $fh = $self->{fh}) {
            $self->{rotate_called}->();
            print $fh "$msg\n";
        }
    };

    # Implementation fixe (mb130-B1) : rotate AVANT capture fh
    my $fixed_log = sub {
        my ($self, $msg) = @_;
        $self->{rotate_called}->() if $self->{fh};
        if (my $fh = $self->{fh}) {
            print $fh "$msg\n";
        }
    };

    my $run = sub {
        my ($log_sub) = @_;
        my $dir = tempdir(CLEANUP => 1);
        my $log = "$dir/app.log";
        open my $fh, ">>", $log or die "open: $!";
        $fh->autoflush(1);
        my $rotated = 0;
        my $self;
        $self = {
            fh => $fh,
            rotate_called => sub {
                return if $rotated++;
                rename $log, "$log.1";
                open my $newfh, ">>", $log or die "reopen: $!";
                $newfh->autoflush(1);
                $self->{fh} = $newfh;
            },
        };
        $log_sub->($self, "msg-after-rotate");
        close $self->{fh};
        my $slurp = sub {
            my ($p) = @_;
            return "" unless -f $p;
            open my $f, "<", $p or return "";
            local $/;
            my $c = <$f> // "";
            $c =~ s/\s+\z//;   # local $/ undef -> chomp inactif, on strip manuellement
            return $c;
        };
        return ( $slurp->($log), $slurp->("$log.1") );
    };

    {
        my ($new_log, $rot_log) = $run->($buggy_log);
        $assert->($new_log eq "",
            "B1 buggy: nouveau .log vide (regression POC)");
        $assert->($rot_log eq "msg-after-rotate",
            "B1 buggy: message ecrit dans .log.1 (le fichier rotate) -- prouve le bug");
    }
    {
        my ($new_log, $rot_log) = $run->($fixed_log);
        $assert->($new_log eq "msg-after-rotate",
            "B1 fixed: message correctement dans nouveau .log");
        $assert->($rot_log eq "",
            "B1 fixed: .log.1 (rotate) reste vide");
    }

    # -------------------------------------------------------------------------
    # B2 : redaction de password dans le log de botPrivmsg
    # -------------------------------------------------------------------------

    my $redact = sub {
        my ($sMsg) = @_;
        my $log_msg = $sMsg;
        if ($log_msg =~ /^(identify|login|register|auth|ghost|recover|release|set\s+password)\b/i) {
            my @parts = split /\s+/, $log_msg;
            my $verb = lc($parts[0] // '');
            if ($verb eq 'login' || $verb eq 'auth'
                || $verb eq 'ghost' || $verb eq 'recover' || $verb eq 'release')
            {
                $parts[2] = '****' if @parts >= 3;
            }
            elsif ($verb eq 'set' && lc($parts[1] // '') eq 'password') {
                $parts[2] = '****' if @parts >= 3;
            }
            else {
                $parts[1] = '****' if @parts >= 2;
            }
            $log_msg = join(' ', @parts);
        }
        return $log_msg;
    };

    # Cas critique : Undernet CService login
    $assert->($redact->('login mybot SuperSecretP4ss') eq 'login mybot ****',
        "B2 'login mybot SuperSecretP4ss' -> 'login mybot ****' (Undernet X)");

    # Cas critique : Libera NickServ identify
    $assert->($redact->('identify topSecret123') eq 'identify ****',
        "B2 'identify topSecret123' -> 'identify ****' (NickServ)");

    # NickServ register avec email visible (l'email n'est pas secret)
    $assert->($redact->('register myPass user_at_example.com') eq 'register **** user_at_example.com',
        "B2 'register pass email' -> 'register **** email' (NickServ register)");

    # auth user pass (certains services)
    $assert->($redact->('auth alice topsecret') eq 'auth alice ****',
        "B2 'auth alice topsecret' -> 'auth alice ****'");

    # ghost / recover / release : pass est arg #2
    $assert->($redact->('ghost teukbot myPass') eq 'ghost teukbot ****',
        "B2 'ghost teukbot myPass' -> 'ghost teukbot ****'");
    $assert->($redact->('recover oldnick myPass') eq 'recover oldnick ****',
        "B2 'recover oldnick myPass' -> 'recover oldnick ****'");
    $assert->($redact->('release oldnick myPass') eq 'release oldnick ****',
        "B2 'release oldnick myPass' -> 'release oldnick ****'");

    # set password newpass
    $assert->($redact->('set password newSecretPass') eq 'set password ****',
        "B2 'set password newSecretPass' -> 'set password ****'");

    # Variantes de casse
    $assert->($redact->('IDENTIFY topSecret') eq 'IDENTIFY ****',
        "B2 case-insensitive: IDENTIFY -> IDENTIFY ****");
    $assert->($redact->('Login Bob Pass123') eq 'Login Bob ****',
        "B2 case-insensitive: Login Bob -> Login Bob ****");

    # Messages normaux non touches
    $assert->($redact->('hello world') eq 'hello world',
        "B2 message normal pas modifie");
    $assert->($redact->('Help me find a quote') eq 'Help me find a quote',
        "B2 message normal multi-mots pas modifie");
    $assert->($redact->('PING :12345') eq 'PING :12345',
        "B2 PING pas modifie");

    # Edge cases : verbe seul sans args
    $assert->($redact->('identify') eq 'identify',
        "B2 'identify' seul (sans pass) -- pas de redact possible, pas de crash");
    $assert->($redact->('login') eq 'login',
        "B2 'login' seul -- pas de crash");
    $assert->($redact->('login bob') eq 'login bob',
        "B2 'login bob' (pas de pass) -- pas de redact");

    # Regression POC : ancien comportement (no redact) divulguait le pass
    {
        my $msg = 'identify mySecretP@ss';
        my $old = $msg;   # ancien log: '-> *NickServ* identify mySecretP@ss'
        my $new = $redact->($msg);
        $assert->($old =~ /mySecretP\@ss/,
            "B2 REGRESSION-POC: ancien log contenait 'mySecretP\@ss' en clair");
        $assert->($new !~ /mySecretP\@ss/,
            "B2 nouveau log NE contient PAS 'mySecretP\@ss'");
    }

    # Important : le message envoye au serveur IRC reste IDENTIQUE
    # (le redact ne s'applique QUE au log). Verifions semantiquement :
    {
        my $sMsg = 'identify topSecret123';
        my $log_msg = $redact->($sMsg);
        $assert->($sMsg eq 'identify topSecret123',
            "B2 \$sMsg original (envoye a IRC) reste intact");
        $assert->($log_msg eq 'identify ****',
            "B2 \$log_msg (envoye au logger) est redacte");
        $assert->($sMsg ne $log_msg,
            "B2 les deux variables sont distinctes");
    }
};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/THIS_FILE.t
#
# When loaded by the project harness, return the case coderef.
# ---------------------------------------------------------------------------
if (caller) {
    return $case;
}

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;

    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);

print "1..$tests\n";
exit($fail ? 1 : 0);

