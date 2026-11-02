// Dış komut çalıştırma: tek kenar adaptörü. Komut başarısızsa çıkış kodu, stderr ve argümanlarla `CommandError`.
import { spawn } from "node:child_process";

/** Çalıştırılan dış komut sıfır olmayan kodla bitti ya da hiç başlamadı. */
export class CommandError extends Error {
  override readonly name: string = "CommandError";
  readonly command: string;
  readonly args: readonly string[];
  readonly exitCode: number | null;
  readonly stderr: string;

  constructor(command: string, args: readonly string[], exitCode: number | null, stderr: string, cause: Error | null) {
    super(
      `Komut başarısız (kod ${exitCode ?? "yok"}): ${command} ${args.map((arg: string) => JSON.stringify(arg)).join(" ")}\n${stderr.trim()}`,
      cause === null ? {} : { cause },
    );
    this.command = command;
    this.args = args;
    this.exitCode = exitCode;
    this.stderr = stderr;
  }
}

/** Komutun çıktısı. */
export interface CommandResult {
  readonly stdout: string;
  readonly stderr: string;
}

/** Komutu `cwd`'de, `env` ortamıyla çalıştırır ve bitmesini bekler; sıfır olmayan kodda `CommandError`. */
export async function runCommand(
  command: string,
  args: readonly string[],
  cwd: string,
  env: Readonly<Record<string, string>>,
): Promise<CommandResult> {
  return await new Promise<CommandResult>((resolve: (result: CommandResult) => void, reject: (error: Error) => void) => {
    const child = spawn(command, args, { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", (error: Error) => reject(new CommandError(command, args, null, "", error)));
    child.on("close", (code: number | null) => {
      const stdout: string = Buffer.concat(out).toString("utf8");
      const stderr: string = Buffer.concat(err).toString("utf8");
      if (code === 0) {
        resolve({ stdout, stderr });
      } else {
        reject(new CommandError(command, args, code, stderr.length > 0 ? stderr : stdout, null));
      }
    });
  });
}
