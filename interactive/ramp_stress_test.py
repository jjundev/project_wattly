import multiprocessing
import time
import math
import sys

def worker(total_duration):
    start_time = time.time()
    while True:
        elapsed = time.time() - start_time
        if elapsed >= total_duration:
            break
        
        # Smooth bell curve from 0.0 -> 1.0 -> 0.0 (Sine envelope)
        progress = elapsed / total_duration
        target_load = max(0.01, math.sin(progress * math.pi) ** 1.2)
        
        # Duty cycle per 30ms slice
        slice_duration = 0.03
        busy_duration = slice_duration * target_load
        sleep_duration = slice_duration * (1.0 - target_load)
        
        t0 = time.time()
        while time.time() - t0 < busy_duration:
            _ = math.sqrt(12345.67) * math.sin(78.9)
            
        if sleep_duration > 0.001:
            time.sleep(sleep_duration)

def monitor(total_duration):
    start_time = time.time()
    while True:
        elapsed = time.time() - start_time
        if elapsed >= total_duration:
            break
        progress = elapsed / total_duration
        load_pct = int(math.sin(progress * math.pi) ** 1.2 * 100)
        
        if progress < 0.25:
            stage = "🌱 1단계: 초저전력 대기 (1W~3W → 잔잔한 물결)"
        elif progress < 0.50:
            stage = "📈 2단계: 가속 구간 (5W~15W → 물결 상승 & 속도 가속)"
        elif progress < 0.75:
            stage = "🔥 3단계: 피크 부하 (20W~40W+ → 최대 진폭 & 고속 질주)"
        else:
            stage = "🍃 4단계: 쿨다운 복귀 (점점 낮아져 1W 잔잔한 대기로 복귀)"
            
        bar_len = 20
        filled = int(bar_len * (load_pct / 100.0))
        bar = "█" * filled + "░" * (bar_len - filled)
        
        sys.stdout.write(f"\r⏱️ [{elapsed:4.1f}s / {total_duration:.0f}s] [{bar}] 부하율: {load_pct:3d}% | {stage}")
        sys.stdout.flush()
        time.sleep(0.5)
    print("\n")

if __name__ == '__main__':
    total_duration = 20.0 # 20 seconds
    num_cores = multiprocessing.cpu_count()
    print(f"\n🚀 [20초 점진적 전력 부하 테스트 시작]")
    print(f"👉 메뉴바의 펄스 웨이브 아이콘을 주목해주세요! (0% → 100% → 0%)\n")
    
    processes = []
    for _ in range(num_cores):
        p = multiprocessing.Process(target=worker, args=(total_duration,))
        p.start()
        processes.append(p)
        
    monitor_proc = multiprocessing.Process(target=monitor, args=(total_duration,))
    monitor_proc.start()
    
    for p in processes:
        p.join()
    monitor_proc.join()
    
    print("✅ [20초 점진적 부하 테스트 완료] 메뉴바 아이콘이 다시 1W 대기 상태로 복귀했습니다.\n")
