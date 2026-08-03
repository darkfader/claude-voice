# claude-voice/scripts/dictation/mdns_advertise.py
"""Advertises this machine's PTT UDP listener via mDNS as "_claudeptt._udp",
so the firmware (claude_ptt.h) can find it automatically on whichever
network it's currently on (home, work, ...) instead of needing a
hardcoded-per-network IP baked into the firmware.
"""
import socket

from zeroconf import ServiceInfo, Zeroconf

SERVICE_TYPE = '_claudeptt._udp.local.'


def _local_ip():
    """Best-effort LAN IP via a UDP "connect" -- no packet is actually sent
    (UDP connect() just picks a route), so this works even fully offline."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        return s.getsockname()[0]
    finally:
        s.close()


class MdnsAdvertiser:
    def __init__(self, port, instance_name='Claude PTT Bridge'):
        ip = _local_ip()
        hostname = socket.gethostname()
        self._zeroconf = Zeroconf()
        self._info = ServiceInfo(
            SERVICE_TYPE,
            f'{instance_name}.{SERVICE_TYPE}',
            addresses=[socket.inet_aton(ip)],
            port=port,
            server=f'{hostname}.local.',
        )
        self._zeroconf.register_service(self._info)
        print(f'mDNS: advertising {SERVICE_TYPE} as {ip}:{port} ({hostname}.local.)')

    def close(self):
        self._zeroconf.unregister_service(self._info)
        self._zeroconf.close()
