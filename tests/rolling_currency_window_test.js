const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.resolve(__dirname, "..", "slim_farm.lua"), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const WINDOW = 60;
const CAPACITY = 128;

class RollingCurrency {
    constructor(at, balance) {
        this.startedAt = at;
        this.lastBalance = balance;
        this.totalEarned = 0;
        this.totalSpent = 0;
        this.times = new Array(CAPACITY);
        this.amounts = new Array(CAPACITY);
        this.head = 0;
        this.count = 0;
        this.rolling = 0;
    }

    prune(now) {
        const cutoff = now - WINDOW;
        while (this.count > 0 && this.times[this.head] < cutoff) {
            this.rolling -= this.amounts[this.head];
            this.times[this.head] = undefined;
            this.amounts[this.head] = undefined;
            this.head = (this.head + 1) % CAPACITY;
            this.count -= 1;
        }
    }

    append(now, amount) {
        if (this.count === CAPACITY) {
            this.rolling -= this.amounts[this.head];
            this.times[this.head] = undefined;
            this.amounts[this.head] = undefined;
            this.head = (this.head + 1) % CAPACITY;
            this.count -= 1;
        }
        const tail = (this.head + this.count) % CAPACITY;
        this.times[tail] = now;
        this.amounts[tail] = amount;
        this.count += 1;
        this.rolling += amount;
    }

    update(now, balance, enabled = true) {
        const delta = balance - this.lastBalance;
        this.prune(now);
        if (enabled && delta > 0) {
            this.totalEarned += delta;
            this.append(now, delta);
        } else if (enabled && delta < 0) {
            this.totalSpent -= delta;
        }
        this.lastBalance = balance;
    }
}

const sample = new RollingCurrency(0, 1000);
sample.update(1, 1100);       // +100
sample.update(60, 1100);
assert(sample.rolling === 100, "first minute boundary reset the window");
sample.update(61, 1300);      // exact 60s boundary retains +100, then adds +200
assert(sample.rolling === 300, "exact 60-second entry was discarded");
sample.update(61.001, 1300);  // +100 is now older than 60 seconds
assert(sample.rolling === 200, "entry older than 60 seconds was retained");
sample.update(121, 1600);     // exact second boundary: +200 remains, add +300
assert(sample.rolling === 500, "second minute boundary reset the window");
sample.update(121.001, 1600);
assert(sample.rolling === 300, "second expired entry was not pruned");
sample.update(181, 2000);     // exact third boundary: +300 remains, add +400
assert(sample.rolling === 700, "third minute boundary reset the window");
sample.update(181.001, 2000);
assert(sample.rolling === 400, "third expired entry was not pruned");

const earnedBeforeSpend = sample.totalEarned;
sample.update(182, 1750);
assert(sample.totalEarned === earnedBeforeSpend,
    "a spend reduced gross session income");
assert(sample.totalSpent === 250, "spend accounting is incorrect");
sample.update(183, 1750);
assert(sample.count === 1, "zero delta was retained in the rolling window");

const format = (amount) => {
    const suffixes = [[1e3, "K"], [1e6, "M"], [1e9, "B"], [1e12, "T"]];
    let index = -1;
    for (let cursor = suffixes.length - 1; cursor >= 0; cursor -= 1) {
        if (Math.abs(amount) >= suffixes[cursor][0]) {
            index = cursor;
            break;
        }
    }
    if (index < 0) return String(Math.round(amount));
    const parts = (cursor) => {
        const scaled = amount / suffixes[cursor][0];
        const decimals = Math.abs(scaled) >= 100 ? 0 : Math.abs(scaled) >= 10 ? 1 : 2;
        const factor = 10 ** decimals;
        return [Math.round(scaled * factor) / factor, decimals];
    };
    let [scaled, decimals] = parts(index);
    if (Math.abs(scaled) >= 1000 && index < suffixes.length - 1) {
        index += 1;
        [scaled, decimals] = parts(index);
    }
    return `${scaled.toFixed(decimals)}${suffixes[index][1]}`;
};
assert(format(999_999_999) === "1.00B", "999M transition produced 1000M");
assert(format(1_000_000_000) === "1.00B", "1B formatting is incorrect");

for (const marker of [
    "CURRENCY_WINDOW_SECONDS = 60",
    "CURRENCY_WINDOW_CAPACITY = 128",
    "sample.RollingEarned",
    "sample.TotalSpent",
    "buildCurrencyMap(save, currencyNames)",
]) {
    assert(source.includes(marker), `missing rolling-window marker: ${marker}`);
}
assert(!source.includes("WindowStartedAt")
    && !source.includes("table.remove(sample.Window"),
    "legacy minute buckets or O(n) head removal remain");
const balancesFunction = source.slice(
    source.indexOf("function currencyMonitor:GetBalances"),
    source.indexOf("function currencyMonitor:Update")
);
assert((balancesFunction.match(/Library\.Save\.Get\(\)/g) || []).length === 1,
    "telemetry reads Library.Save more than once per sample");

process.stdout.write(
    "Rolling currency window OK | boundaries=3 | gross/spend=separate | 999M=1.00B\n"
);
