# Work in progress: self dot in init
# Notes: this module is still being drafted;
# names and signatures may change before review.
# Keep helpers small and avoid side effects at import time.
class Account:
    def __init__(self, owner, balance=0):
        self.owner = owner
        self.balance = balance
        self.‸

    def deposit(self, amount):
        self.balance += amount

    def statement(self):
        return f"{self.owner}: {self.balance}"
