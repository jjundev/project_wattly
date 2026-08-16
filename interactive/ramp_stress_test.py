import multiprocessing
import time
import math

def worker(total_duration):
    start_time = time.time()
    while True:
        elapsed = time.time() - start_time
        if elapsed >= total_duration:
            break
        
        # Smooth bell curve from 0.0 -> 1.0 -> 0.0 (Sine envelope)
        progress = elapsed / total_duration
        target_load = max(0.02, math.sin(progress * math.pi) ** 1.1)
        
        # Duty cycle per 30ms slice
        slice_duration = 0.03
        busy_duration = slice_duration * target_load
        sleep_duration = slice_duration * (1.0 - target_load)
        
        t0 = time.time()
        while time.time() - t0 < busy_duration:
            _ = math.sqrt(12345.67) * math.sin(78.9)
            
        if sleep_duration > 0.001:
            time.sleep(sleep_duration)

if __name__ == '__main__':
    total_duration = 20.0 # 20 seconds
    num_cores = multiprocessing.cpu_count()
    print(f"🚀 [20초 점진적 부하 테스트 시작] {num_cores}개 코어에서 20초간 0% → 100% → 0% 스윙을 시작합니다.")
    processes = []
    for _ in range(num_cores):
        p = multiprocessing.Process(target=worker, args=(total_duration,))
        p.start()
        processes.append(p)
    for p in processes:
        p.join()
    print("✅ [20초 점진적 부하 테스트 완료]")
