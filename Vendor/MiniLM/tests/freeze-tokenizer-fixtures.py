#!/usr/bin/env python3
"""Build-time fixture generation only: frozen synthetic words, no model import/session."""
from pathlib import Path
import hashlib
import json
import sys
from tokenizers import Tokenizer

assets = Path(sys.argv[1])
output = Path(__file__).resolve().parent
expected = 'df45d9da01151c111d5ccdc39ac4ae51899197879f295db0bd521136af468ca5'
assert hashlib.sha256((assets / 'tokenizer.json').read_bytes()).hexdigest() == expected
tokenizer = Tokenizer.from_file(str(assets / 'tokenizer.json'))
tokenizer.no_truncation()
tokenizer.no_padding()
words = ['please', 'send', 'the', 'revised', 'notes', 'before', 'lunch', 'tomorrow',
         'hello', 'world', 'don\'t', 'can’t', 'co-operate', '3.14', '12,345', 'café',
         'naïve', 'résumé', 'हिन्दी', '日本語', '中文', '한국어', 'ελληνικά', 'привет',
         'العربية', 'שלום', '🧪', '\U0010ffff', 'z' * 2000, 'newyork', 'a', 'é', 'e\u0301']
rows = []
for word in words:
    ids = tokenizer.encode(word, add_special_tokens=False).ids
    rows.append(' '.join(str(i) for i in ids) + '\t' + word)
(output / 'tokenizer-fixtures.tsv').write_text('\n'.join(rows) + '\n')
(output / 'tokenizer-fixtures.json').write_text(json.dumps({
    'source': 'Authored public synthetic lexical fixtures; no user text.',
    'generator': 'Hugging Face tokenizers.Tokenizer.encode(add_special_tokens=False); no_truncation/no_padding',
    'tokenizer_revision': '970138a82387e72360e9e3591cd5237a9f47ec5c',
    'tokenizer_json_sha256': expected,
    'fixture_count': len(words),
    'fixture_sha256': hashlib.sha256((output / 'tokenizer-fixtures.tsv').read_bytes()).hexdigest(),
    'scope': 'Tokenizer parity only; no model session or inference.'
}, indent=2) + '\n')
print('Froze', len(words), 'synthetic tokenizer-only fixtures; no model session/inference.')
