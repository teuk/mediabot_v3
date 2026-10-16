package Mediabot::AI::MetaPassages;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use Mediabot::AI::MetaPolicy qw(clean safe_url);
use Mediabot::AI::MetaEvidence qw(validate_support);
our @EXPORT_OK=qw(build_catalogue resolve_support);

sub _fingerprint {
    my ($source)=@_;
    return sha256_hex(encode('UTF-8',join("\0",$source->{id},$source->{url},
        Mediabot::AI::MetaEvidence::_literal($source->{text}))));
}
sub build_catalogue {
    my ($sources)=@_;
    return undef unless ref($sources) eq 'ARRAY' && @$sources && @$sources<=3;
    my (@rows,%lookup,%snapshots,%seen);
    for my $source (@$sources) {
        return undef unless ref($source) eq 'HASH' && defined($source->{id}) && !ref($source->{id})
            && $source->{id}=~/\A[1-3]\z/ && !$seen{$source->{id}}++ && safe_url($source->{url});
        my $text=Mediabot::AI::MetaEvidence::_literal($source->{text});
        $text=substr($text,0,5000);
        my $fingerprint=_fingerprint($source);my @passages;my $ordinal=0;
        # The extractor joins non-contiguous fragments with this separator.
        # Never manufacture a single proof passage spanning that join.
        for my $fragment (split /\s+\x{2026}\s+/,$text) {
            my $offset=0;
            while ($offset<length($fragment) && @passages<40) {
                my $piece=substr($fragment,$offset,240);my $width=length($piece);
                if ($offset+$width<length($fragment)) {
                    my $space=rindex($piece,' ');
                    if ($space>=180) {$piece=substr($piece,0,$space);$width=$space}
                }
                $piece=~s/^\s+|\s+$//g;
                if (length($piece)>=12) {
                    my $suffix=substr(sha256_hex(encode('UTF-8',join("\0",$fingerprint,++$ordinal,$piece))),0,12);
                    my $id='s'.$source->{id}.'p'.$ordinal.'-'.$suffix;
                    return undef if exists($lookup{$id});
                    $lookup{$id}={source_id=>0+$source->{id},quote=>$piece};
                    push @passages,{passage_id=>$id,text=>$piece};
                }
                last if $offset+$width>=length($fragment);
                # Small overlap preserves details straddling a chunk boundary.
                $offset+=$width-32;
            }
        }
        next unless @passages;
        my %row=(id=>0+$source->{id},url=>$source->{url},passages=>\@passages);
        for my $key (qw(title date kind date_status retrieved)) {
            $row{$key}=clean($source->{$key},$key eq 'title'?140:40)
                if defined($source->{$key}) && !ref($source->{$key});
        }
        $snapshots{$source->{id}}=$fingerprint;
        push @rows,\%row;
    }
    return @rows?{sources=>\@rows,lookup=>\%lookup,snapshots=>\%snapshots}:undef;
}
sub resolve_support {
    my ($parsed,$cited,$catalogue)=@_;
    return (undef,'missing') unless ref($parsed) eq 'HASH'
        && exists($parsed->{basis}) && exists($parsed->{support});
    return (undef,'invalid') unless defined($parsed->{basis}) && !ref($parsed->{basis})
        && $parsed->{basis}=~/\A(?:supported|partial|insufficient)\z/
        && ref($parsed->{support}) eq 'ARRAY' && @{$parsed->{support}}<=2
        && ref($cited) eq 'ARRAY' && @$cited && @$cited<=2;
    return (undef,'missing') unless @{$parsed->{support}};
    return (undef,'invalid') unless ref($catalogue) eq 'HASH'
        && ref($catalogue->{lookup}) eq 'HASH' && ref($catalogue->{snapshots}) eq 'HASH';
    my %sources;
    for my $source (@$cited) {
        return (undef,'invalid') unless ref($source) eq 'HASH' && defined($source->{id})
            && !ref($source->{id}) && $source->{id}=~/\A[1-3]\z/ && !exists($sources{$source->{id}})
            && safe_url($source->{url});
        $sources{$source->{id}}=$source;
    }
    my (%seen,@resolved);
    for my $anchor (@{$parsed->{support}}) {
        return (undef,'invalid') unless ref($anchor) eq 'HASH' && keys(%$anchor)==2
            && exists($anchor->{source_id}) && exists($anchor->{passage_id})
            && defined($anchor->{source_id}) && !ref($anchor->{source_id})
            && $anchor->{source_id}=~/\A[1-3]\z/ && exists($sources{$anchor->{source_id}})
            && !$seen{$anchor->{source_id}}++ && defined($anchor->{passage_id}) && !ref($anchor->{passage_id});
        my $id=$anchor->{passage_id};
        return (undef,'unknown_passage') unless $id=~/\As[1-3]p[1-9][0-9]?-[0-9a-f]{12}\z/
            && exists($catalogue->{lookup}{$id});
        my $row=$catalogue->{lookup}{$id};
        return (undef,'unknown_passage') unless ref($row) eq 'HASH' && defined($row->{source_id})
            && !ref($row->{source_id}) && $row->{source_id}==$anchor->{source_id};
        return (undef,'source_changed') unless defined($catalogue->{snapshots}{$anchor->{source_id}})
            && _fingerprint($sources{$anchor->{source_id}}) eq $catalogue->{snapshots}{$anchor->{source_id}};
        push @resolved,{source_id=>0+$anchor->{source_id},quote=>$row->{quote}};
    }
    return (undef,'missing') if grep {!$seen{$_->{id}}} @$cited;
    my $result={%$parsed,support=>\@resolved};
    my $error=validate_support($result,$cited);
    return defined($error)?(undef,$error):($result,undef);
}
1;
