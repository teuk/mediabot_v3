package TestClassifier;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    allowed_test_classes
    classify_test_file
    classify_test_source
);

my @CLASSES = qw(PURE FILESYSTEM PROCESS DB NETWORK);

# MB660: conservative source-touchpoint classification.
#
# These tags describe what a test's source appears to interact with. They are
# intentionally broader than "requires a real external resource": a test that
# mocks DBI, inspects SQL text or validates HTTP code may still carry DB or
# NETWORK. That bias is deliberate. Most importantly, these tags are NOT a
# parallel-safety certification. Parallel execution remains out of scope until
# a later reviewed pass explicitly proves which tests are safe to overlap.
my %RULES = (
    FILESYSTEM => [
        # Read-only source inspection is intentionally not enough for this tag.
        # FILESYSTEM means a test appears to create/mutate filesystem state.
        qr/\bFile::Temp\b/,
        qr/\bFile::Path\b/,
        qr/\b(?:tempdir|tempfile)\s*\(/,
        qr/\b(?:sysopen|unlink|rename|mkdir|rmdir|chdir|chmod|lstat|readlink|symlink)\s*(?:\(|\b)/,
        qr/\b(?:copy|move)\s*\(/,
        qr/\bopen\s+[^;\n]*,\s*['"](?:>>?|[+<>]{2,})/,
    ],
    PROCESS => [
        qr/\b(?:fork|exec|system|kill|wait|waitpid)\s*(?:\(|\b)/,
        qr/\bIPC::/,
        qr/\bIO::Async::Process\b/,
        qr/\bPOSIX::_exit\b/,
        qr/\bopen\s*\([^;\n]*['"]-\|/,
        qr/\bqx\s*[\{\(\[\/]/,
    ],
    DB => [
        qr/\bDBI\b/,
        qr/\bDBD::/,
        qr/\bMariaDB\b/i,
        qr/\bmysql\b/i,
        qr/\bmariadb\b/i,
        qr/\bdbh\b/i,
        qr/->prepare\s*\(/,
        qr/\b(?:SELECT|INSERT|UPDATE|DELETE|REPLACE|CREATE\s+TABLE|ALTER\s+TABLE|DROP\s+TABLE|TRUNCATE)\b/i,
    ],
    NETWORK => [
        qr/\bIO::Socket(?:::\w+)?\b/,
        qr/\bSocket\b/,
        qr/\bNet::[A-Za-z0-9_:]+\b/,
        qr/\b(?:HTTP::|LWP::|Mojo::UserAgent|AnyEvent::HTTP)\b/,
        qr/\b(?:get_http_async|http_get|http_request|connect_irc|connect_to_server)\b/i,
        qr/\b(?:curl|wget|openssl\s+s_client|nc\s+-)\b/i,
    ],
);

my @PRIMARY_PRECEDENCE = qw(NETWORK DB PROCESS FILESYSTEM PURE);

sub allowed_test_classes {
    return @CLASSES;
}

sub classify_test_source {
    my ($src, %opts) = @_;
    $src = '' unless defined $src;

    my %tags;
    for my $class (qw(FILESYSTEM PROCESS DB NETWORK)) {
        for my $pattern (@{ $RULES{$class} }) {
            if ($src =~ $pattern) {
                $tags{$class} = 1;
                last;
            }
        }
    }

    # Standalone TAP files are executed through a subprocess by test_commands.pl
    # even if their own source otherwise looks pure.
    $tags{PROCESS} = 1 if $opts{isolated};

    $tags{PURE} = 1 unless keys %tags;

    my ($primary) = grep { $tags{$_} } @PRIMARY_PRECEDENCE;
    my @ordered_tags = grep { $tags{$_} } @CLASSES;

    return {
        primary => $primary,
        tags    => \@ordered_tags,
    };
}

sub classify_test_file {
    my ($file, %opts) = @_;

    open my $fh, '<:encoding(UTF-8)', $file
        or die "cannot classify test file $file: $!\n";
    local $/;
    my $src = <$fh>;
    close $fh;

    return classify_test_source($src, %opts);
}

1;
