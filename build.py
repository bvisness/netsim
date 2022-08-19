#!/usr/bin/env python3

import glob
import os
import re
import subprocess
import random
import shutil
import string
import sys

RELEASE = len(sys.argv) > 1 and sys.argv[1] == 'release'

odin = 'odin'
clang = 'clang'
wasmld = 'wasm-ld'

try:
    subprocess.run(['clang-10', '-v'], stderr=subprocess.DEVNULL)
    clang = 'clang-10'
except FileNotFoundError:
    pass

try:
    subprocess.run(['wasm-ld-10', '-v'], stdout=subprocess.DEVNULL)
    wasmld = 'wasm-ld-10'
except FileNotFoundError:
    pass

[os.remove(f) for f in glob.iglob('build/dist/*', recursive=True)]
for ext in ['*.o', '*.wasm', '*.wat']:
    [os.remove(f) for f in glob.iglob('build/**/' + ext, recursive=True)]

os.makedirs('build', exist_ok=True)

print('Compiling...')
subprocess.run([
    odin,
    'build', 'src',
    '-target:js_wasm32',
    '-out:build/netsim.wasm',
    '-o:size'
])

# Optimize output WASM file
if RELEASE:
    print('Optimizing WASM...')
    subprocess.run([
        'wasm-opt', 'build/netsim.wasm',
        '-o', 'build/netsim.wasm',
        '-O2', # general perf optimizations
        '--memory-packing', # remove unnecessary and extremely large .bss segment
        '--zero-filled-memory',
    ])

# Patch memcpy and memmove
print('Patching WASM...')
subprocess.run([
    'wasm2wat',
    '-o', 'build/netsim.wat',
    'build/netsim.wasm',
])
memcpy = """(\\1
    local.get 0
    local.get 1
    local.get 2
    memory.copy
    local.get 0)"""
with open('build/netsim.wat', 'r') as infile, open('build/netsim_patched.wat', 'w') as outfile:
    wat = infile.read()
    wat = re.sub(r'\((func \$memcpy.*?\(result i32\)).*?local.get 0(.*?return)?\)', memcpy, wat, flags=re.DOTALL)
    wat = re.sub(r'\((func \$memmove.*?\(result i32\)).*?local.get 0(.*?return)?\)', memcpy, wat, flags=re.DOTALL)
    outfile.write(wat)
subprocess.run([
    'wat2wasm',
    '-o', 'build/netsim_patched.wasm',
    'build/netsim_patched.wat',
])

#
# Output the dist folder for upload
#

print('Building dist folder...')
os.makedirs('build/dist', exist_ok=True)

buildId = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8)) # so beautiful. so pythonic.

root = 'src/index.html'
assets = [
    'src/normalize.css',
    'src/runtime.js',
    'build/netsim_patched.wasm',
]

rootContents = open(root).read()

def addId(filename, id):
    parts = filename.split('.')
    parts.insert(-1, buildId)
    return '.'.join(parts)

for asset in assets:
    basename = os.path.basename(asset)
    newFilename = addId(basename, buildId)
    shutil.copy(asset, 'build/dist/{}'.format(newFilename))

    rootContents = rootContents.replace(basename, newFilename)

with open('build/dist/index.html', 'w') as f:
    f.write(rootContents)

print('Done!')
