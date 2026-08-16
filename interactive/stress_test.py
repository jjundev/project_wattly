import multiprocessing
import time
import math

def worker(duration):
    end = time.time() + duration
    x = 0.0001
    while time.time() < end:
        x = math.sin(x) * math.cos(x) + math.sqrt(abs(x) + 1.0)

if __name__ == '__main__':
    duration = 15 # 15 seconds
    num_cores = multiprocessing.cpu_count()
    print(f"Starting CPU stress test on {num_cores} cores for {duration} seconds...")
    processes = []
    for _ in range(num_cores):
        p = multiprocessing.Process(target=worker, args=(duration,))
        p.start()
        processes.append(p)
    for p in processes:
        p.join()
    print("Stress test finished.")
