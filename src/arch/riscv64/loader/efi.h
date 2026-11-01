/*
 * The small part of UEFI (specification 2.10) that the loader uses. The
 * structure layouts must match the specification exactly: functions the
 * loader does not call are kept as void * placeholders, so that the ones
 * it calls are at the right offsets.
 */
#ifndef LAZUL_EFI_H
#define LAZUL_EFI_H

#include <stdint.h>

/* UEFI on RISC-V uses the standard calling convention (x86-64 does not). */
#define	EFIAPI

typedef uint64_t efi_status;
typedef void *efi_handle;
typedef uint16_t char16;

#define	EFI_SUCCESS		0
#define	EFI_ERROR_BIT		(1ULL << 63)
#define	EFI_LOAD_ERROR		(EFI_ERROR_BIT | 1)
#define	EFI_INVALID_PARAMETER	(EFI_ERROR_BIT | 2)
#define	EFI_BUFFER_TOO_SMALL	(EFI_ERROR_BIT | 5)

typedef struct {
	uint32_t	a;
	uint16_t	b, c;
	uint8_t		d[8];
} efi_guid;

#define	EFI_LOADED_IMAGE_PROTOCOL_GUID					\
	{ 0x5b1b31a1, 0x9562, 0x11d2,					\
	    { 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define	EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID				\
	{ 0x964e5b22, 0x6459, 0x11d2,					\
	    { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
/* Configuration table entry holding the device tree (a DTB). */
#define	EFI_DTB_TABLE_GUID						\
	{ 0xb1b621d5, 0xf19c, 0x41a5,					\
	    { 0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 } }
/* RISC-V EFI boot protocol: which hart the firmware booted on. */
#define	RISCV_EFI_BOOT_PROTOCOL_GUID					\
	{ 0xccd15fec, 0x6f73, 0x4eec,					\
	    { 0x83, 0x95, 0x3e, 0x69, 0xe4, 0xb9, 0x40, 0xbf } }

typedef struct {
	uint64_t	signature;
	uint32_t	revision, header_size, crc32, reserved;
} efi_table_header;

typedef struct efi_simple_text_output {
	void		*reset;
	efi_status	(EFIAPI *output_string)(
			    struct efi_simple_text_output *, const char16 *);
} efi_simple_text_output;

enum efi_allocate_type {
	ALLOCATE_ANY_PAGES,
	ALLOCATE_MAX_ADDRESS,
	ALLOCATE_ADDRESS
};

enum efi_memory_type {
	EFI_LOADER_CODE = 1,
	EFI_LOADER_DATA = 2,
	EFI_CONVENTIONAL_MEMORY = 7	/* free memory */
};

/*
 * One entry of the memory map. Entries are desc_size bytes apart, which
 * may be more than sizeof(efi_memory_descriptor).
 */
typedef struct {
	uint32_t	type;
	uint32_t	pad;
	uint64_t	physical_start, virtual_start;
	uint64_t	number_of_pages, attribute;
} efi_memory_descriptor;

typedef struct {
	efi_table_header hdr;
	void		*raise_tpl, *restore_tpl;
	efi_status	(EFIAPI *allocate_pages)(enum efi_allocate_type,
			    enum efi_memory_type, uint64_t pages,
			    uint64_t *addr);
	efi_status	(EFIAPI *free_pages)(uint64_t addr, uint64_t pages);
	efi_status	(EFIAPI *get_memory_map)(uint64_t *size, void *map,
			    uint64_t *key, uint64_t *desc_size,
			    uint32_t *desc_version);
	efi_status	(EFIAPI *allocate_pool)(enum efi_memory_type,
			    uint64_t size, void **buf);
	efi_status	(EFIAPI *free_pool)(void *buf);
	void		*create_event, *set_timer, *wait_for_event;
	void		*signal_event, *close_event, *check_event;
	void		*install_protocol_interface;
	void		*reinstall_protocol_interface;
	void		*uninstall_protocol_interface;
	efi_status	(EFIAPI *handle_protocol)(efi_handle,
			    const efi_guid *, void **iface);
	void		*reserved, *register_protocol_notify, *locate_handle;
	void		*locate_device_path, *install_configuration_table;
	void		*load_image, *start_image, *exit, *unload_image;
	efi_status	(EFIAPI *exit_boot_services)(efi_handle image,
			    uint64_t map_key);
	void		*get_next_monotonic_count, *stall;
	void		*set_watchdog_timer;
	void		*connect_controller, *disconnect_controller;
	void		*open_protocol, *close_protocol;
	void		*open_protocol_information;
	void		*protocols_per_handle, *locate_handle_buffer;
	efi_status	(EFIAPI *locate_protocol)(const efi_guid *,
			    void *registration, void **iface);
} efi_boot_services;

typedef struct {
	efi_guid	guid;
	void		*table;
} efi_configuration_table;

typedef struct {
	efi_table_header hdr;
	char16		*firmware_vendor;
	uint32_t	firmware_revision;
	efi_handle	console_in_handle;
	void		*con_in;
	efi_handle	console_out_handle;
	efi_simple_text_output *con_out;
	efi_handle	standard_error_handle;
	efi_simple_text_output *std_err;
	void		*runtime_services;
	efi_boot_services *boot_services;
	uint64_t	number_of_table_entries;
	efi_configuration_table *configuration_table;
} efi_system_table;

typedef struct {
	uint32_t	revision;
	efi_handle	parent_handle;
	efi_system_table *system_table;
	efi_handle	device_handle;
	void		*file_path, *reserved;
	uint32_t	load_options_size;
	void		*load_options;
	void		*image_base;
	uint64_t	image_size;
	enum efi_memory_type image_code_type, image_data_type;
	void		*unload;
} efi_loaded_image;

#define	EFI_FILE_MODE_READ	1
#define	EFI_FILE_POSITION_END	0xffffffffffffffffULL

typedef struct efi_file {
	uint64_t	revision;
	efi_status	(EFIAPI *open)(struct efi_file *, struct efi_file **,
			    const char16 *name, uint64_t mode, uint64_t attrs);
	efi_status	(EFIAPI *close)(struct efi_file *);
	void		*delete_;
	efi_status	(EFIAPI *read)(struct efi_file *, uint64_t *size,
			    void *buf);
	void		*write;
	efi_status	(EFIAPI *get_position)(struct efi_file *,
			    uint64_t *pos);
	efi_status	(EFIAPI *set_position)(struct efi_file *, uint64_t pos);
} efi_file;

typedef struct efi_simple_file_system {
	uint64_t	revision;
	efi_status	(EFIAPI *open_volume)(struct efi_simple_file_system *,
			    efi_file **root);
} efi_simple_file_system;

typedef struct riscv_efi_boot_protocol {
	uint64_t	revision;
	efi_status	(EFIAPI *get_boot_hartid)(
			    struct riscv_efi_boot_protocol *, uint64_t *hartid);
} riscv_efi_boot_protocol;

#endif
