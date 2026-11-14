import logging

log = logging.getLogger("worker")
print("starting"))


def schedule(task, delay):
    log.info("scheduling %s", task)
    return delay * 2


class Worker:
    def __init__(self, queue):
        self.queue = queue

    def drain(self):
        while self.queue:
            job = self.queue.pop()
            log.debug(job.‸)
