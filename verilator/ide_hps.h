#pragma once

#include "Vz386_mister_system_core.h"

#include <cstdint>
#include <string>
#include <vector>

#define ATA_STATUS_RDY  0x40
#define ATA_STATUS_RDP  0x20
#define ATA_STATUS_DSC  0x10
#define ATA_STATUS_DRQ  0x08
#define ATA_STATUS_IRQ  0x04
#define ATA_STATUS_END  0x02
#define ATA_STATUS_ERR  0x01

struct HpsIdeRegs {
    uint8_t io_size = 0;
    uint8_t error = 0;
    uint16_t sector_count = 1;
    uint16_t sector = 1;
    uint32_t cylinder = 0;
    uint8_t head = 0;
    uint8_t drv = 0;
    uint8_t lba = 0;
    uint8_t cmd = 0;
    uint16_t pkt_io_size = 0;
    uint8_t status = ATA_STATUS_RDY;
};

struct HpsIdeDrive {
    bool present = false;
    uint16_t cylinders = 0;
    uint16_t heads = 16;
    uint16_t spt = 63;
    uint32_t total_sectors = 0;
    uint32_t spb = 16;
    uint16_t id[256] = {};
};

class HpsIde {
public:
    explicit HpsIde(uint8_t id, uint16_t base_addr);

    bool open(const std::string& path);
    bool present() const { return drive_.present; }
    void set_debug(bool debug) { debug_ = debug; }
    void tick(Vz386_mister_system_core& tb);

private:
    enum State {
        INITIAL,
        IDLE,
        RESET_SET,
        GET_CMD,
        DO_CMD,
        SEND_ID,
        SET_REGS,
        SET_REGS_SEND,
        READ,
        READ_REGS,
        READ_SEND,
        READ_WAIT_REQ,
        WRITE,
        WRITE_REGS,
        WRITE_RECV
    };

    void pulse_read(Vz386_mister_system_core& tb, uint16_t addr);
    void pulse_write(Vz386_mister_system_core& tb, uint16_t addr, uint16_t data);
    void clear_bus(Vz386_mister_system_core& tb);
    void handle_cmd();
    void set_geometry(uint16_t sectors, uint16_t heads);
    void update_identify();
    uint32_t get_lba() const;
    void put_lba(uint32_t lba);

    uint8_t id_;
    uint16_t base_;
    State state_ = INITIAL;
    State next_state_ = IDLE;
    HpsIdeRegs regs_;
    HpsIdeDrive drive_;
    std::vector<uint8_t> image_;
    std::string image_name_;
    uint16_t* sector_words_ = nullptr;
    uint32_t sector_ = 0;
    uint32_t sector_count_ = 0;
    uint32_t cylinder_ = 0;
    uint8_t drv_addr_ = 0;
    uint8_t cmd_ = 0;
    uint8_t buf_[12] = {};
    int cnt_ = 0;
    uint8_t irq_pending_ = 0;
    bool bus_cooldown_ = false;
    bool debug_ = false;
};
