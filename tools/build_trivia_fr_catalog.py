#!/usr/bin/env python3
"""Build the pinned, attributed OpenQuizzDB French catalog; no SQL or network."""
import argparse
import hashlib
import json
import re
import subprocess
import unicodedata
from pathlib import Path

REVISION = 'a16819964d171e40e6652368fc562f3bd27d0c5b'
SOURCE = 'https://github.com/Zeuh/OpenQuizzDB'
CATEGORIES = {
    9: ('Culture générale', [9,28,44,53,58,67,77,79,80,93,96,99,101,111,113,125,129,132,134,154,155,157,158,161,166,168,172,181,190,205,207,209,219,226,228,233,244,246,249,254,259,260,265,266,277,294,457,550,555]),
    10: ('Littérature', [3,87,139,140]),
    11: ('Cinéma', [34,43,46,47,51,52,55,57,59,63,81,88,89,90,92,163,214,241,243,250,256,257,273]),
    12: ('Musique', [38,39,56,62,85,95,103,136,159,182,194,197,236,238,269]),
    14: ('Télévision', [18,31,36,41,114,177,189,192,267]),
    15: ('Jeux vidéo', [35,102,204,261]),
    17: ('Sciences et nature', [65,71,97,123,126,151,164,199,206,224]),
    18: ('Informatique', [32,37,45,196,223,232,234,239,365,403]),
    20: ('Mythologie et traditions', [33,122,142,180,195,405]),
    21: ('Sports', [23,26,60,72,73,84,108,138,143,144,150,153,176,185,187,191,211,212,245,262,264,268,272,383]),
    22: ('Géographie', [14,22,30,61,66,68,94,100,104,105,109,112,115,117,121,130,133,135,174,193,203,208,221,231,247,251,255,263]),
    23: ('Histoire', [8,70,82,98,120,127,160,183,188,382,543]),
    25: ('Arts', [69,86,128,202]),
    27: ('Animaux', [48,49,50,116,145,173,175,184,237,413]),
}

def folded(text):
    return ''.join(c for c in unicodedata.normalize('NFD', text.casefold())
                   if not unicodedata.combining(c)).replace('œ', 'oe').replace('’', "'")

def clean(value):
    if not isinstance(value, str) or re.search(r'[\x00-\x1f\x7f-\x9f]', value):
        raise ValueError('invalid text')
    value = re.sub(r'\s+', ' ', value).strip()
    if not value:
        raise ValueError('empty text')
    return value

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source-root', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    revision = subprocess.check_output(['git','-C',str(args.source_root),'rev-parse','HEAD'], text=True).strip()
    if revision != REVISION:
        raise SystemExit('Source revision differs from the reviewed catalog pin.')
    rows, sources, skipped, seen = [], [], [], set()
    levels = {'débutant':'easy', 'confirmé':'medium', 'expert':'hard'}
    for category, (label, ids) in CATEGORIES.items():
        for quiz in ids:
            path = args.source_root / 'data' / f'openquizzdb_{quiz}.json'
            try:
                raw = path.read_bytes()
                doc = json.loads(raw.decode('utf-8-sig'))
                groups = doc['quizz'].get('fr', doc['quizz'])
                if isinstance(groups, list) and len(groups) == 1:
                    groups = groups[0]
                if not isinstance(groups, dict) or set(groups) != set(levels):
                    raise ValueError('question groups')
                author, title = clean(doc['rédacteur']), clean(doc['thème'])
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                skipped.append({'quiz':quiz, 'reason':'invalid_source'})
                continue
            count = 0
            for level, difficulty in levels.items():
                for row in groups[level]:
                    try:
                        question, answer = clean(row['question']), clean(row['réponse'])
                        options = [clean(v) for v in row['propositions']]
                        qid = row['id']
                        if type(qid) is not int or not 1 <= qid <= 100:
                            raise ValueError('id')
                        if len(options) != 4 or options.count(answer) != 1:
                            raise ValueError('answer')
                        if len({folded(v) for v in options}) != 4:
                            raise ValueError('ambiguous answers')
                        # Keep complete questions and all choices inside IRC budgets.
                        if len(question.encode()) > 300 or any(len(v.encode()) > 90 for v in options):
                            raise ValueError('text budget')
                        if sum(len(v.encode()) + 4 for v in options) > 260:
                            raise ValueError('choices budget')
                        signature = folded(question)
                        if signature in seen:
                            raise ValueError('duplicate question')
                        seen.add(signature)
                    except (ValueError, KeyError, TypeError):
                        skipped.append({'quiz':quiz, 'question':row.get('id'), 'reason':'invalid_or_duplicate_question'})
                        continue
                    rows.append({'id':f'oqdb-{quiz}-{qid}', 'category_id':category,
                        'question':question, 'correct_answer':answer,
                        'incorrect_answers':[v for v in options if v != answer],
                        'difficulty':difficulty, 'category':label,
                        'theme':title, 'author':author, 'quiz':quiz})
                    count += 1
            if count:
                sources.append({'quiz':quiz,'title':title,'author':author,'questions':count,
                    'url':f'{SOURCE}/blob/{revision}/data/{path.name}',
                    'path':str(path.relative_to(args.source_root)),
                    'sha256':hashlib.sha256(raw).hexdigest()})
    document = {'version':1,'language':'fr','license':'CC-BY-SA-4.0',
        'license_url':'https://creativecommons.org/licenses/by-sa/4.0/',
        'credit':'OpenQuizzDB — https://www.openquizzdb.org',
        'source_repository':SOURCE, 'source_revision':revision, 'source_snapshot_date':'2022-02-12',
        'modifications':'French extraction; category mapping; whitespace normalization; bounded text, ambiguous-answer and duplicate filtering. Wording and answer keys otherwise retained.',
        'sources':sources, 'skipped':skipped, 'questions':rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    counts = {label:sum(r['category_id']==cid for r in rows) for cid,(label,_) in CATEGORIES.items()}
    print(json.dumps({'questions':len(rows),'quizzes':len(sources),'categories':counts,'skipped':len(skipped)},ensure_ascii=False))

if __name__ == '__main__':
    main()
