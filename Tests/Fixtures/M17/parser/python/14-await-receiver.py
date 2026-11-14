import asyncio

MAX_RETRIES = 3


async def run_job(job):
    await asyncio.sleep(0)
    return job


async def fetch_all(session, urls):
    results = []
    for url in urls:
        resp = (await session.get(url)).‸
        results.append(resp)
    return results


async def main():
    print(await fetch_all(None, []))
