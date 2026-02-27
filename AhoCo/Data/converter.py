import dpkt
import sys
import time
import os
from tqdm import tqdm

def pcap_to_payload_fast(pcap_file, output_file):
    # 1. Obtenir la taille totale du fichier pour la barre de progression
    try:
        total_size = os.path.getsize(pcap_file)
    except FileNotFoundError:
        print(f"❌ Erreur: Fichier '{pcap_file}' introuvable.")
        return

    print(f"🚀 Début de l'extraction de {pcap_file} ({total_size / (1024*1024*1024):.2f} Go)")
    start_time = time.time()
    
    count = 0
    total_payload_bytes = 0
    
    with open(pcap_file, 'rb') as f_in, open(output_file, 'wb') as f_out:
        
        try:
            pcap = dpkt.pcap.Reader(f_in)
        except ValueError:
            f_in.seek(0)
            pcap = dpkt.pcapng.Reader(f_in)

        # 2. Initialisation de la barre de progression tqdm
        # unit='B' et unit_scale=True permettent d'afficher des KB, MB, GB automatiquement
        with tqdm(total=total_size, unit='B', unit_scale=True, desc="Progression") as pbar:
            
            last_pos = f_in.tell() # Position initiale du curseur
            
            for ts, buf in pcap:
                # --- MISE À JOUR DE LA BARRE ---
                current_pos = f_in.tell()
                pbar.update(current_pos - last_pos) # On ajoute les octets qu'on vient de lire
                last_pos = current_pos
                # -------------------------------
                
                try:
                    eth = dpkt.ethernet.Ethernet(buf)
                    
                    if not isinstance(eth.data, dpkt.ip.IP) and not isinstance(eth.data, dpkt.ip6.IP6):
                        continue
                    
                    ip = eth.data
                    
                    if isinstance(ip.data, dpkt.tcp.TCP) or isinstance(ip.data, dpkt.udp.UDP):
                        payload = ip.data.data 
                        
                        if payload:
                            f_out.write(payload)
                            total_payload_bytes += len(payload)
                            count += 1
                            
                except Exception:
                    continue

    elapsed_time = time.time() - start_time
    size_mb = total_payload_bytes / (1024 * 1024)
    
    print("\n" + "-" * 40)
    print("✅ Extraction terminée !")
    print(f"Paquets utiles (avec payload) : {count:,}")
    print(f"Taille totale du payload      : {size_mb:.2f} MB")
    print(f"Temps d'exécution             : {elapsed_time:.2f} secondes")
    if elapsed_time > 0:
        print(f"Vitesse moyenne               : {size_mb / elapsed_time:.2f} MB/s")
    print("-" * 40)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python pcap_to_bin_fast.py <input.pcap> <output.bin>")
    else:
        pcap_to_payload_fast(sys.argv[1], sys.argv[2])