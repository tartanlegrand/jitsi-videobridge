// Override focus host for benchmark environment
config.hosts.focus = 'focus.meet.jitsi';
config.hosts.anonymousdomain = 'guest.meet.jitsi';
config.focusUserJid = 'focus@auth.meet.jitsi';
// Use WebSocket for bridge channel (avoids ICE/UDP issues in Docker)
config.bridgeChannel = {
    preferSctp: false
};
