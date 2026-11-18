"""Separate measured text formatting counters; audio usage remains unknown."""
import json
import os
import tempfile
from pathlib import Path
from datetime import datetime, timezone


def empty():
    return dict(calls=0,successful=0,failed=0,input_tokens=0,output_tokens=0,total_tokens=0,unreported=0)

class FormattingMetrics:
    def __init__(self,path):
        self.path=Path(path);self.healthy=True
        self.data={'tracking_since':datetime.now(timezone.utc).isoformat(),'totals':empty()}
        if self.path.exists():
            try:
                if self.path.stat().st_size>10000:raise ValueError('Oversized counters')
                data=json.loads(self.path.read_text())
                if set(data['totals'])!=set(empty()) or any(type(v) is not int or v<0 for v in data['totals'].values()):raise ValueError('Invalid counters')
                self.data=data
            except (OSError,ValueError,KeyError,TypeError):self.healthy=False

    def persist(self):
        if not self.healthy:return
        name=None
        try:
            self.path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            fd,name=tempfile.mkstemp(prefix='.formatting-',dir=self.path.parent);os.fchmod(fd,0o600)
            with os.fdopen(fd,'w') as out:
                json.dump(self.data,out);out.flush();os.fsync(out.fileno())
            os.replace(name,self.path)
        except OSError:self.healthy=False
        finally:
            if name and os.path.exists(name):os.unlink(name)

    def call(self):
        self.data['totals']['calls']+=1;self.persist()

    def finish(self,success,usage):
        totals=self.data['totals'];totals['successful' if success else 'failed']+=1
        if success:
            if usage:
                for k in ['input_tokens','output_tokens','total_tokens']:totals[k]+=usage[k]
            else:totals['unreported']+=1
        self.persist()

    def snapshot(self):
        return {**self.data,'totals':dict(self.data['totals']),'storage_healthy':self.healthy,
                'note':'Reported tokens cover profile text formatting only, not audio transcription or your subscription percentage.'}
