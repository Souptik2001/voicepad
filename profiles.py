"""Nine fixed instruction slots, atomically stored independently of audio/auth."""
import copy
import json
import os
import tempfile
from pathlib import Path

class ProfileError(Exception):
    pass


def validate_profile(slot, name, instructions):
    if type(slot) is not int or not 1 <= slot <= 9:
        raise ValueError('Choose a profile slot from 1 to 9.')
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 60:
        raise ValueError('Profile name must contain 1–60 characters.')
    if not isinstance(instructions, str) or len(instructions) > 4000:
        raise ValueError('Instructions must be text of at most 4000 characters.')
    return {'slot':slot, 'name':name.strip(), 'instructions':instructions}


class Profiles:
    def __init__(self, path):
        self.path=Path(path)
        self.items={}
        self.healthy=True
        if self.path.exists():
            try:
                if self.path.stat().st_size > 500000:
                    raise ValueError('Oversized profiles')
                saved=json.loads(self.path.read_text())
                if set(saved) != {'version','profiles'} or saved['version']!=1 or not isinstance(saved['profiles'],list) or len(saved['profiles'])>9:
                    raise ValueError('Invalid storage')
                for item in saved['profiles']:
                    if not isinstance(item,dict) or set(item)!={'slot','name','instructions'}:
                        raise ValueError('Invalid profile')
                    p=validate_profile(**item)
                    if p['slot'] in self.items:
                        raise ValueError('Duplicate slot')
                    self.items[p['slot']]=p
            except (OSError,ValueError,TypeError,KeyError):
                self.healthy=False

    def snapshot(self):
        if not self.healthy:
            raise ProfileError('Profiles could not be read. Saved data has not been reset; repair the profiles file.')
        return {'profiles':copy.deepcopy([self.items[s] for s in sorted(self.items)])}

    def get(self, slot):
        self.snapshot()
        return copy.deepcopy(self.items.get(slot))

    def save(self, slot, payload=None):
        self.snapshot()
        candidate=copy.deepcopy(self.items)
        if payload is None:
            candidate.pop(slot,None)
        else:
            candidate[slot]=validate_profile(slot,**payload)
        name=None
        try:
            self.path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            descriptor,name=tempfile.mkstemp(prefix='.profiles-',dir=self.path.parent)
            os.fchmod(descriptor,0o600)
            with os.fdopen(descriptor,'w') as output:
                json.dump({'version':1,'profiles':[candidate[s] for s in sorted(candidate)]},output,ensure_ascii=False)
                output.flush();os.fsync(output.fileno())
            os.replace(name,self.path)
            self.items=candidate
        except OSError:
            raise ProfileError('Could not save profiles. Your changes were not applied; please retry.') from None
        finally:
            if name and os.path.exists(name):os.unlink(name)
        return self.snapshot()
