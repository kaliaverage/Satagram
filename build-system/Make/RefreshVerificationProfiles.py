import datetime
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile


source = pathlib.Path('build-system/fake-codesigning')
destination = pathlib.Path(os.environ['RUNNER_TEMP']) / 'satagram-test-signing'
shutil.copytree(source / 'certs', destination / 'certs')
(destination / 'profiles').mkdir(parents=True)

for profile in (source / 'profiles').glob('*.mobileprovision'):
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(profile)], check=True, stdout=subprocess.PIPE).stdout
    data = plistlib.loads(decoded)
    data['ExpirationDate'] = datetime.datetime.utcnow() + datetime.timedelta(days=365)
    data.pop('DER-Encoded-Profile', None)
    with tempfile.NamedTemporaryFile() as plist:
        plist.write(plistlib.dumps(data))
        plist.flush()
        subprocess.run([
            'security', 'cms', '-S', '-k', 'temp.keychain',
            '-N', 'Apple Distribution: Telegram FZ-LLC (C67CF9S4VU)',
            '-i', plist.name, '-o', str(destination / 'profiles' / profile.name)
        ], check=True)
