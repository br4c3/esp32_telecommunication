import {cp, mkdir, rm} from 'node:fs/promises';
import {spawn} from 'node:child_process';

const output = new URL('dist/', import.meta.url);

function run(command, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {cwd, stdio: 'inherit'});
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)));
  });
}

await rm(output, {recursive: true, force: true});
await mkdir(output, {recursive: true});
await run('flutter', ['build', 'web', '--base-href', '/user/', '--output', '../dist/user'], new URL('user-flutter/', import.meta.url));
await cp(new URL('admin-web/', import.meta.url), new URL('admin/', output), {recursive: true});
console.log('Firebase Hosting build complete: /user and /admin');
