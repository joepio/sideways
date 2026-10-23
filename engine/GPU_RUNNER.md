# GPU runner: Claude Code on a Windows machine with a real GPU

The engine is developed in a cloud container without a GPU. A Claude Code
session on a Windows PC runs the renderer on real hardware, offscreen (no
window ever opens: it renders to textures and writes PNG and JSON), and
pushes the results to the `gpu-results` branch, where the cloud session
reads them.

## Once: set up

In PowerShell:

```powershell
# Rust (MSVC toolchain) and the C++ build tools meshoptimizer needs
winget install --id Rustlang.Rustup -e
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
cd C:\dev\sideways
git fetch origin rust-engine
git switch rust-engine
claude
```

## Then paste this prompt into Claude Code

> You are the GPU runner for the Kern engine in C:\dev\sideways (branch
> rust-engine). Never open a window or anything on screen: the renderer
> only renders offscreen. Loop until I stop you:
>
> 1. `git fetch origin rust-engine`. If origin/rust-engine has a new
>    commit since your last run (or this is the first run), `git switch
>    rust-engine && git reset --hard origin/rust-engine`.
> 2. In `engine`, run `cargo run --release -p cli -- gpu-run --out
>    ..\gpu-out` (it builds the renderer, runs the offscreen frames and
>    benchmarks listed in engine/gpu-jobs.toml, and writes PNG/JSON there).
>    If the build or run fails, write the error output to
>    ..\gpu-out\error.txt instead.
> 3. Commit everything in gpu-out to the `gpu-results` branch (create it
>    from an empty orphan the first time; keep only the latest run's files
>    plus a short `log.md` line per run with the commit hash, GPU name and
>    the headline numbers) and push it.
> 4. Wait 5 minutes and go back to 1. If nothing changed, do not rerun.
>
> Keep your replies to one line per run.
