package Mediabot::Plugin::Playful;

use strict;
use warnings;
use utf8;
use Mediabot::IRC::TextBudget qw(_split_text_for_irc _utf8_text_bytes);

sub new {
    my ($class, %args) = @_;
    return bless {
        context        => $args{context},
        roll_history   => {},
        flip_stats     => {},
        choose_history => {},
        choose_last    => {},
    }, $class;
}

sub start { $_[0]{started} = 1; 1 }
sub stop  { $_[0]{started} = 0; 1 }

sub _rand_index {
    my ($self, $size) = @_;
    $size = 1 unless defined($size) && $size > 0;
    # Match the native games: reducing the low bits of the old linear
    # generator modulo two forced every coin to alternate heads/tails.
    return int(rand($size));
}

sub _reply  { $_[0]{context}->reply($_[1], $_[2]) }
sub _notice { $_[0]{context}->notice($_[1], $_[2]) }

sub _reply_text {
    my ($context, $invocation, $text) = @_;
    # PluginContext counts all arguments as character text, including strings
    # that Perl can store as unflagged Latin-1.
    utf8::upgrade($text);
    my @lines = _split_text_for_irc($text, 400);
    my $last = pop @lines;
    for my $line (@lines) {
        return 0 unless $context->reply($invocation, $line);
    }
    return $context->reply($invocation, $last);
}

sub _reply_history {
    my ($context, $invocation, $history, $prefix, $separator) = @_;
    my ($latest, @older) = reverse @$history;
    my $line = $prefix . $latest;
    for my $entry (@older) {
        my $joined = $line . $separator . $entry;
        if (_utf8_text_bytes($joined) > 400) {
            return 0 unless _reply_text($context, $invocation, $line);
            $line = $prefix . $entry;
        } else {
            $line = $joined;
        }
    }
    return _reply_text($context, $invocation, $line);
}

sub command_8ball {
    my ($self, $context, $invocation) = @_;
    my $question = join(' ', @{ $invocation->args });
    $question =~ s/^\s+|\s+$//g;
    return $context->notice($invocation, 'Syntax: 8ball <question>')
        unless length $question;

    my %answers = (
        en => [
            'It is certain.', 'It is decidedly so.', 'Without a doubt.',
            'Yes, definitely.', 'You may rely on it.', 'As I see it, yes.',
            'Most likely.', 'Outlook good.', 'Yes.',
            'Signs point to yes.', 'Reply hazy, try again.',
            'Ask again later.', 'Better not tell you now.',
            'Cannot predict now.', 'Concentrate and ask again.',
            "Don't count on it.", 'My reply is no.', 'My sources say no.',
            'Outlook not so good.', 'Very doubtful.',
        ],
        fr => [
            q{C'est certain.}, q{C'est absolument ça.}, 'Sans aucun doute.',
            'Oui, définitivement.', 'Tu peux compter dessus.',
            'Comme je le vois, oui.', 'Très probablement.',
            'Les perspectives sont bonnes.', 'Oui.',
            'Les signes indiquent que oui.', 'Flou, essaie encore.',
            'Demande plus tard.', 'Mieux vaut ne pas te le dire maintenant.',
            'Je ne peux pas prédire ça.', 'Concentre-toi et redemande.',
            q{N'y compte pas.}, 'Ma réponse est non.',
            'Mes sources disent non.',
            'Les perspectives ne sont pas bonnes.', 'Très douteux.',
        ],
        es => [
            'Definitivamente sí.', 'Por supuesto.', 'Sin ninguna duda.',
            'Sí, definitivamente.', 'Puedes contar con ello.',
            'Las perspectivas son buenas.', 'Muy probablemente.', 'Sí.',
            'Los indicios apuntan que sí.', 'Como yo lo veo, sí.',
            'La respuesta es incierta, intenta de nuevo.',
            'Pregunta más tarde.', 'Mejor no responderte ahora.',
            'No puedo predecirlo.', 'Concéntrate y pregunta de nuevo.',
            'No cuentes con ello.', 'Mi respuesta es no.',
            'Mis fuentes dicen que no.',
            'Las perspectivas no son buenas.', 'Muy dudoso.',
        ],
    );
    my $language = $invocation->config_value('language') || 'fr';
    my $pool = $answers{$language} || $answers{en};
    my $answer = $pool->[ $self->_rand_index(scalar @$pool) ];
    return $context->reply($invocation,
        "\x038\x02[8ball]\x0f " . $invocation->nick . ": $answer");
}

sub command_roll {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my $channel = $invocation->channel;
    my $channel_key = lc($channel // '');
    my $nick = $invocation->nick;

    if (@args && lc($args[0]) eq 'history') {
        my $history = $self->{roll_history}{$channel_key} || [];
        return $context->reply($invocation, "$nick: no roll history on $channel.")
            unless @$history;

        return _reply_history($context, $invocation, $history, 'Last rolls: ', '  |  ');
    }

    my ($number, $sides, $modifier, $mode) = (1, 6, 0, '');
    # Match numeric conversion's ASCII grammar, not Unicode \d.
    if (@args && $args[0] =~ /\A([0-9]+)d([0-9]+)\z/i) {
        ($number, $sides) = (int($1), int($2));
        $number = 1 if $number < 1;
        $number = 20 if $number > 20;
        $sides = 2 if $sides < 2;
        $sides = 100 if $sides > 100;
        shift @args;
    }
    elsif (@args && $args[0] =~ /\A[0-9]+\z/) {
        $sides = int($args[0]);
        $sides = 2 if $sides < 2;
        $sides = 100 if $sides > 100;
        shift @args;
    }
    # With no explicit dice token, the first option belongs to the default 1d6.
    for my $extra (@args) {
        if ($extra =~ /\A([+-][0-9]+)\z/) {
            $modifier = int($1);
            $modifier = 100 if $modifier > 100;
            $modifier = -100 if $modifier < -100;
        }
        elsif ($extra =~ /\Aadv(?:antage)?\z/i) { $mode = 'adv' }
        elsif ($extra =~ /\Adis(?:advantage)?\z/i) { $mode = 'dis' }
    }

    my @rolls = map { 1 + $self->_rand_index($sides) } 1 .. $number;
    my $label = "${number}d${sides}";
    my $out;
    if ($mode && $number == 1) {
        my $second = 1 + $self->_rand_index($sides);
        my ($kept, $dropped) = $mode eq 'adv'
            ? sort { $b <=> $a } ($rolls[0], $second)
            : sort { $a <=> $b } ($rolls[0], $second);
        my $total = $kept + $modifier;
        my $mod = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = sprintf('%s rolled %s (%s): [%d, %s]%s  → %d',
            $nick, $label, $mode, $kept, "\x1e$dropped\x0f", $mod, $total);
    }
    elsif ($number == 1) {
        my $total = $rolls[0] + $modifier;
        my $mod = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = "$nick rolled $label: $rolls[0]$mod";
    }
    else {
        my $sum = 0; $sum += $_ for @rolls;
        my $total = $sum + $modifier;
        my $mod = $modifier ? sprintf(' %+d = %d', $modifier, $total) : " = $sum";
        $out = sprintf('%s rolled %s: [%s]%s',
            $nick, $label, join(', ', @rolls), $mod);
    }
    my $history = $self->{roll_history}{$channel_key} ||= [];
    push @$history, $out;
    splice @$history, 0, @$history - 5 if @$history > 5;
    return $context->reply($invocation, $out);
}

sub command_flip {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my ($channel, $nick) = ($invocation->channel, $invocation->nick);
    my $channel_key = lc($channel // '');
    my $stats = $self->{flip_stats}{$channel_key} ||= { h => 0, t => 0 };
    if (@args && lc($args[0]) eq 'stats') {
        my $total = $stats->{h} + $stats->{t};
        return $context->reply($invocation,
            "$nick: no flips yet on $channel.") unless $total;
        return $context->reply($invocation, sprintf(
            '%s flip stats on %s: %d Heads (%.0f%%)  %d Tails (%.0f%%)  — %d total',
            $nick, $channel, $stats->{h}, 100 * $stats->{h} / $total,
            $stats->{t}, 100 * $stats->{t} / $total, $total));
    }
    my $number = @args && $args[0] =~ /\A[0-9]+\z/ ? int($args[0]) : 1;
    $number = 1 if $number < 1;
    $number = 10 if $number > 10;
    my @results;
    for (1 .. $number) {
        my $result = $self->_rand_index(2) ? 'T' : 'H';
        push @results, $result;
        $result eq 'H' ? $stats->{h}++ : $stats->{t}++;
    }
    return $context->reply($invocation, $number == 1
        ? "$nick flipped a coin: " . ($results[0] eq 'H' ? 'Heads!' : 'Tails!')
        : sprintf('%s flipped %d coins: %s  (%d H, %d T)',
            $nick, $number, join('', @results),
            scalar(grep { $_ eq 'H' } @results),
            scalar(grep { $_ eq 'T' } @results)));
}

sub command_choose {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my ($channel, $nick) = ($invocation->channel, $invocation->nick);
    my $channel_key = lc($channel // '');
    if (@args == 1 && lc($args[0]) eq 'history') {
        my $history = $self->{choose_history}{$channel_key} || [];
        return $context->reply($invocation, "$nick: no choice history on $channel.")
            unless @$history;
        return _reply_history($context, $invocation, $history, 'Last choices: ', ' | ');
    }
    if (@args == 1 && lc($args[0]) eq 'last') {
        my $last = $self->{choose_last}{$channel_key};
        return _reply_text($context, $invocation, defined($last)
            ? "$nick: last choice was: $last"
            : "$nick: no previous choice on this channel.");
    }
    my $raw = join(' ', @args);
    my $separator = $raw =~ /\|/ ? qr/\|/ : qr/\s+ou\s+/i;
    my @raw = grep { length } map {
        my $value = $_; $value =~ s/^\s+|\s+$//g; $value
    } split $separator, $raw;
    my (%seen, @unique);
    push @unique, $_ for grep { !$seen{lc $_}++ } @raw;
    if (@unique < @raw) {
        $context->notice($invocation,
            'Note: ' . (@raw - @unique) . ' duplicate option(s) removed.');
    }
    my @pool;
    for my $option (@unique) {
        if ($option =~ /\A(.+?):([0-9]+)\z/ && $2 >= 1 && $2 <= 20) {
            push @pool, ($1) x $2;
        }
        else { push @pool, $option }
    }
    return $context->notice($invocation,
        'No valid options remain after deduplication.') unless @pool;
    # Repeated weighted entries are still the same result label.
    my %labels = map { lc($_) => 1 } @pool;
    return $context->notice($invocation,
        'Only one option left after deduplication — nothing to choose from.')
        unless keys(%labels) >= 2;
    my $choice = $pool[ $self->_rand_index(scalar @pool) ];
    $self->{choose_last}{$channel_key} = $choice;
    my $history = $self->{choose_history}{$channel_key} ||= [];
    push @$history, $choice;
    splice @$history, 0, @$history - 5 if @$history > 5;
    return _reply_text($context, $invocation,
        "$nick: I choose... $choice!"
            . (@pool > 2 ? ' (1 of ' . scalar(@pool) . ' options)' : ''));
}

my %MORSE_CODE = (
    A=>'.-', B=>'-...', C=>'-.-.', D=>'-..', E=>'.', F=>'..-.',
    G=>'--.', H=>'....', I=>'..', J=>'.---', K=>'-.-', L=>'.-..',
    M=>'--', N=>'-.', O=>'---', P=>'.--.', Q=>'--.-', R=>'.-.',
    S=>'...', T=>'-', U=>'..-', V=>'...-', W=>'.--', X=>'-..-',
    Y=>'-.--', Z=>'--..', '0'=>'-----', '1'=>'.----', '2'=>'..---',
    '3'=>'...--', '4'=>'....-', '5'=>'.....', '6'=>'-....',
    '7'=>'--...', '8'=>'---..', '9'=>'----.',
);
my %MORSE_TEXT = (reverse(%MORSE_CODE), '?' => '?');

sub command_morse {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my $decode = lc($args[0] // '') eq '-d';
    shift @args if $decode;
    my $text = join(' ', @args);
    $text =~ s/^\s+|\s+$//g;
    return $context->notice($invocation,
        'Syntax: morse <text> | morse -d <Morse code>') unless length $text;

    if ($decode) {
        my $too_long = 'Morse input too long. Split it into shorter messages.';
        # InvocationV3 keeps up to 32 arguments of 256 characters. At either
        # limit the original code may have been truncated before dispatch.
        return $context->notice($invocation, $too_long)
            if @args > 30 || grep { length($_) >= 256 } @args;
        my @words;
        for my $word (split m{/}, $text, -1) {
            my @symbols = split ' ', $word;
            return $context->notice($invocation,
                'Invalid Morse. Separate letters with spaces and words with /.')
                if !@symbols || grep { !exists $MORSE_TEXT{$_} } @symbols;
            push @words, join('', map { $MORSE_TEXT{$_} } @symbols);
        }
        my $decoded = join(' ', @words);
        return $context->notice($invocation, $too_long) if length($decoded) > 400;
        return $context->reply($invocation, $decoded);
    }

    $text = uc $text;
    return $context->notice($invocation, 'Text too long (max 80 chars).')
        if length($text) > 80;
    my $result = join(' / ', map {
        join(' ', map { $MORSE_CODE{$_} // '?' } split //)
    } split /\s+/, $text);
    # Encoded Morse is ASCII, with spaces between all symbols.
    while (length($result) > 400) {
        my $cut = rindex($result, ' ', 400);
        return 0 unless $context->reply($invocation, substr($result, 0, $cut));
        $result = substr($result, $cut + 1);
    }
    return $context->reply($invocation, $result);
}

sub command_abbrev {
    my ($self, $context, $invocation) = @_;
    my $text = join(' ', @{ $invocation->args });
    $text =~ s/^\s+|\s+$//g;
    return $context->notice($invocation, 'Syntax: abbrev <text>')
        unless length $text;
    my @words = split /\s+/, $text;
    my $abbrev = join('', map { uc substr($_, 0, 1) } @words);
    return $context->reply($invocation,
        $invocation->nick . ": $abbrev (" . scalar(@words) . ' word(s))');
}

sub job_quiet_magic {
    my ($self, $context, $invocation) = @_;
    return 0 unless $invocation->config_value('ritual_enabled');
    my $every = $invocation->config_value('ritual_every') || 4;
    return 0 if $invocation->sequence % $every;
    my $language = $invocation->config_value('language') || 'fr';
    my $style = $invocation->config_value('ritual_style') || 'subtle';
    my %lines = (
        fr => {
            subtle => [
                'Une minuscule chouette en papier traverse le canal, vérifie que tout va bien, puis repart très professionnelle.',
                'Quelque part dans le canal, une théière invisible vient de faire « ding ». Personne ne sait pourquoi, mais le timing est impeccable.',
                'Un petit courant d’air feuillette les vieux messages et remet discrètement une virgule à sa place.',
            ],
            chaos => [
                'ALERTE TRÈS MODÉRÉE : trois chaussettes viennent de fonder un ministère provisoire dans le canal.',
                'Une pluie de confettis administratifs vient de valider le formulaire B-42. Le canal peut continuer.',
                'Le plafond imaginaire s’ouvre : un canard en cravate inspecte le canal, prend une note, puis disparaît.',
            ],
        },
        en => {
            subtle => [
                'A tiny paper owl crosses the channel, checks that everything is fine, then leaves looking very professional.',
                'An invisible teapot just went “ding” somewhere in the channel. Nobody knows why, but the timing was excellent.',
                'A small draft flips through the old messages and quietly puts one comma back in place.',
            ],
            chaos => [
                'VERY MODERATE ALERT: three socks have founded a provisional ministry in the channel.',
                'A shower of administrative confetti has approved form B-42. The channel may continue.',
                'The imaginary ceiling opens: a duck in a tie inspects the channel, takes one note, and vanishes.',
            ],
        },
        es => {
            subtle => [
                'Un pequeño búho de papel cruza el canal, comprueba que todo va bien y se marcha muy profesional.',
                'Una tetera invisible acaba de hacer «ding». Nadie sabe por qué, pero el momento fue perfecto.',
                'Una corriente de aire hojea los mensajes antiguos y coloca discretamente una coma en su sitio.',
            ],
            chaos => [
                'ALERTA MUY MODERADA: tres calcetines han fundado un ministerio provisional en el canal.',
                'Una lluvia de confeti administrativo ha aprobado el formulario B-42. El canal puede continuar.',
                'El techo imaginario se abre: un pato con corbata inspecciona el canal, toma nota y desaparece.',
            ],
        },
    );
    my $pool = $lines{$language}{$style} || $lines{en}{subtle};
    my $line = $pool->[ $self->_rand_index(scalar @$pool) ];
    return $context->channel_message($invocation, $line);
}

1;
