#!/usr/bin/python3
import os
import sys
import pathlib
import subprocess

from pathlib import Path

DEP_ROOT_ARM64 = "/Users/msvoboda/LocalHome/Dev/IINA/mpv-macos-build-v0.40.0"
DEP_ROOT_X86_64 = "/Users/msvoboda/LocalHome/Dev/IINA/mpv-macos-build-v0.40.0-x86_64"

class LibArtifact:
  name: str
  relpath_from_dep_root: str
  
  def __init__(self, name: str, relpath_from_dep_root: str):
    self.name = name
    self.relpath_from_dep_root = relpath_from_dep_root


ARTIFACTS = [
  LibArtifact('libplacebo', f'homebrew/Cellar/libplacebo/7.349.0/lib/libplacebo.349.dylib'),
  LibArtifact('libmpv', f'mpv/build/libmpv.2.dylib'),
]

class ScriptError(Exception):
  msg: str
  
  def __init__(self, msg: str):
    self.msg = msg


# Print to stderr
def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def main():
  if sys.version_info[0] < 3:
    eprint("Python 3 or a more recent version is required.")
    exit(-1)

  # if len(sys.argv) < 2:
  #   eprint("ERROR: No arguments supplied!")
  #   exit(1)
  # tgt = sys.argv[1]
  
  try:
    script_dir = os.path.dirname(os.path.realpath(__file__))
    print(f'Script dir: {script_dir}')
    
    project_root_dir = os.path.abspath(f'{script_dir}/..')
    print(f'Project root dir: {project_root_dir}')
    
    output_lib_dir = os.path.abspath(f'{project_root_dir}/deps/lib')
    
    # Check that directories are valid; error out if any are not
    for req_dir in [DEP_ROOT_ARM64, DEP_ROOT_X86_64, output_lib_dir]:
      if os.path.isdir(req_dir):
        print(f'Found: {req_dir}')
      else:
        raise ScriptError(f'Dir not found: {req_dir}')
    
    ans = subprocess.check_output(['python3', '--version'], text=True)
    
    
    for art in ARTIFACTS:
      art_arm64 = os.path.abspath(f'{DEP_ROOT_ARM64}/{art.relpath_from_dep_root}')
      art_x86_64 = os.path.abspath(f'{DEP_ROOT_X86_64}/{art.relpath_from_dep_root}')
      # Add leading '_' to filename while still working. Will change later
      out_file_name = f'_{os.path.basename(art.relpath_from_dep_root)}'
      out_path = os.path.join(output_lib_dir, out_file_name)
      lipo_argv = ['lipo', '-create', art_arm64, art_x86_64, '-output', out_path]
      
      print(lipo_argv)
      # subprocess.check_output blocks until command exits
      output_str = subprocess.check_output(lipo_argv, text=True)
      print(output_str)
    
  except ScriptError as e:
    eprint(f'ERROR: {e.msg}')
    exit(99)
  except subprocess.CalledProcessError as e:
    eprint(f"Command failed with return code {e.returncode}")
    exit(e.returncode)
  except e:
    eprint(f"Command failed with return code {e.message}")
    exit(1)
  
  print('Done.')

if __name__ == '__main__':
  main()
