#!/usr/bin/env python3
"""Initialize private API state as the bot account. Never print token contents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
from radio_service import Backend, RadioError, require


def initialize(bot_config, storage, owner=None, identity='local'):
    storage = Path(storage)
    incoming = storage / 'incoming'
    require(storage.is_dir() and incoming.is_dir(), 'create_shared_storage_first')
    require(str(storage) == str(storage.resolve()) and storage.stat().st_uid == os.getuid(), 'storage_owner')
    data = Backend({'bot_config': str(bot_config)}).catalogue('preflight', owner=owner)
    if owner is None:
        require(len(data['owners']) == 1, 'choose_existing_catalogue_owner_with_owner_id')
        owner = int(data['owners'][0]['id_user'])
    else:
        require(int(data['owner_valid']) == owner, 'unknown_catalogue_owner')
    v = data['config']
    require(v['LIQUIDSOAP_TELNET_HOST'] in ('127.0.0.1', 'localhost'), 'local_liquidsoap_required')
    require(identity.isascii() and identity.replace('_','').replace('-','').isalnum(), 'invalid_identity')
    control, state = storage / 'control', storage / 'state'
    require(not control.exists() and not control.is_symlink() and not state.exists() and not state.is_symlink(), 'state_already_initialized')
    control.mkdir(mode=0o700)
    state.mkdir(mode=0o700)
    token = secrets.token_hex(32)
    config = dict(listen_host='127.0.0.1',listen_port=8765,
                  bot_config=str(bot_config),incoming=str(incoming),database=str(state/'jobs.sqlite'),
                  catalogue_owner=owner, music_roots=sorted(set(data['roots']+[str(incoming)])),
                  liquidsoap_port=int(v['LIQUIDSOAP_TELNET_PORT']),queue_id=v['LIQUIDSOAP_QUEUE_ID'],
                  yt_dlp=v['YTDLP_PATH'] or '/usr/local/bin/yt-dlp',cookies=v['YTDLP_COOKIES_FILE'],
                  remote_components=v['YTDLP_REMOTE_COMPONENTS'],js_runtime='node',max_duration=900,
                  token_hashes={identity:hashlib.sha256(token.encode()).hexdigest()})
    from radio_service import validate_config
    validate_config(config)
    for path, text in ((control/'client.token',token+'\n'),
                       (control/'service.json',json.dumps(config,indent=2)+'\n')):
        with path.open('x') as f:
            os.fchmod(f.fileno(),0o600)
            f.write(text)
    return config


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--bot-config',required=True,type=Path)
    parser.add_argument('--storage',default='/var/lib/mediabot-radio',type=Path)
    parser.add_argument('--owner-id',type=int)
    parser.add_argument('--identity',default='local')
    args=parser.parse_args()
    os.umask(0o077)
    try:
        initialize(args.bot_config.resolve(strict=True),args.storage,args.owner_id,args.identity)
        print('Radio API initialized: '+str(args.storage/'control/service.json'))
        print('Client token file: '+str(args.storage/'control/client.token'))
    except Exception as e:
        raise SystemExit('Radio setup: '+(e.code if isinstance(e,RadioError) else type(e).__name__))
