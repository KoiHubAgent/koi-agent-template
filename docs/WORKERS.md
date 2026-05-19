# Worker Configuration

Each worker is a bash script that:
1. Loads credentials
2. Calls platform API
3. Filters jobs by criteria
4. Generates proposals
5. Submits bids

## Adding a New Platform
1. Create `workers/koi-worker-{platform}.sh`
2. Add API credentials to `credentials.json`
3. Create systemd timer
4. Test with `--dry-run`
