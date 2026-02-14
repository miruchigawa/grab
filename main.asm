; =============================================================================
; Grab: High-Performance Search in Assembly
;
; A minimal, fast grep-like tool using AVX2 instructions and direct Linux syscalls.
;
; Build: make
; Usage: ./grab <pattern> <filename>
; =============================================================================

section .data
    ; --- Constants ---
    SYS_WRITE   equ 1
    SYS_OPEN    equ 2
    SYS_CLOSE   equ 3
    SYS_FSTAT   equ 5
    SYS_LSEEK   equ 8
    SYS_MMAP    equ 9
    SYS_MUNMAP  equ 11
    SYS_EXIT    equ 60

    ; Open flags
    O_RDONLY    equ 0

    ; Lseek whence
    SEEK_END    equ 2

    ; Mmap flags
    PROT_READ   equ 1
    MAP_PRIVATE equ 2

    ; File status
    S_IFMT      equ 0xF000
    S_IFDIR     equ 0x4000

    ; Error codes (positive values for comparison)
    ENOENT      equ 2
    EACCES      equ 13
    ENOMEM      equ 12
    EISDIR      equ 21
    EFBIG       equ 27

    ; Configuration
    OUT_BUF_SIZE equ 65536

    ; --- Strings ---
    msg_usage db "Usage: ./grab <pattern> <filename>", 10
    msg_usage_len equ $ - msg_usage
    
    msg_err_prefix db "Error: ", 0
    msg_err_prefix_len equ 7

    ; Error messages
    err_no_file    db "No such file or directory", 0
    err_no_perm    db "Permission denied", 0
    err_is_dir     db "Is a directory", 0
    err_no_mem     db "Out of memory", 0
    err_too_big    db "File too large", 0
    err_unknown    db "Unknown error code: ", 0

    newline db 10

section .bss
    last_printed_end resq 1
    out_buf resb OUT_BUF_SIZE
    out_buf_ptr resq 1
    num_scratch resb 32
    stat_buf resb 144  ; size of struct stat

section .text
    global _start

_start:
    ; --- Initialization ---
    mov qword [last_printed_end], 0
    mov qword [out_buf_ptr], out_buf

    ; --- Argument Parsing ---
    pop rax             ; argc
    cmp rax, 3
    jne usage_exit

    pop rdi             ; skip argv[0]

    pop r12             ; argv[1] (pattern)
    mov rdi, r12
    call strlen
    mov r13, rax        ; r13 = pattern length
    test r13, r13
    jz exit_flush       ; Empty pattern: exit

    pop rdi             ; argv[2] (filename)

    ; --- File Operations ---
    ; Open file
    mov rax, SYS_OPEN
    mov rsi, O_RDONLY
    syscall
    test rax, rax
    js open_error
    mov r14, rax        ; r14 = file descriptor

    ; Check if directory
    mov rax, SYS_FSTAT
    mov rdi, r14
    mov rsi, stat_buf
    syscall
    test rax, rax
    js .skip_fstat      ; Ignore fstat errors, try to read anyway
    
    mov eax, [stat_buf + 24] ; st_mode
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .skip_fstat
    
    mov rax, EISDIR     ; Simulate EISDIR error
    jmp open_error

.skip_fstat:
    ; Get file size
    mov rax, SYS_LSEEK
    mov rdi, r14
    mov rsi, 0
    mov rdx, SEEK_END
    syscall
    test rax, rax
    js lseek_error
    mov r15, rax        ; r15 = file size
    
    ; Memory map file
    mov rax, SYS_MMAP
    mov rdi, 0
    mov rsi, r15
    mov rdx, PROT_READ
    mov r10, MAP_PRIVATE
    mov r8, r14         ; fd
    mov r9, 0           ; offset
    syscall
    
    ; Check mmap error (returns -4095 to -1 on error)
    cmp rax, -4095
    ja mmap_error
    mov rbx, rax        ; rbx = mapped memory start

    ; Check if file is smaller than pattern
    cmp r15, r13
    jl exit_flush

    ; --- Search Setup ---
    ; Prepare AVX2 vectors for first and last byte of pattern
    ; This allows dual-checking to reduce false positives
    vpbroadcastb ymm1, [r12]          ; ymm1 = pattern[0] repeated
    
    mov r11, r13
    dec r11
    vpbroadcastb ymm3, [r12 + r11]    ; ymm3 = pattern[len-1] repeated
    
    mov r10, rbx
    add r10, r11        ; r10 = ptr to check last byte (buffer + len - 1)

    xor rsi, rsi        ; rsi = current offset
    mov rdx, r15
    sub rdx, 32         ; Safe limit for AVX2 load
    sub rdx, r11        ; Adjust for pattern length
    jl .scalar_loop

    ; --- Main AVX2 Search Loop ---
.avx_loop:
    cmp rsi, rdx
    jge .scalar_loop
    
    ; Check first byte
    vmovdqu ymm0, [rbx + rsi]
    vpcmpeqb ymm2, ymm0, ymm1   ; ymm2 = mask of matches for first byte
    
    ; Check last byte
    vmovdqu ymm4, [r10 + rsi]
    vpcmpeqb ymm5, ymm4, ymm3   ; ymm5 = mask of matches for last byte
    
    ; Combine checks
    vpand ymm2, ymm2, ymm5      ; ymm2 = positions where BOTH match
    
    vpmovmskb eax, ymm2         ; Move mask to general register
    
    test eax, eax
    jz .next_chunk              ; No matches in this 32-byte chunk
    
    call process_chunk
    
.next_chunk:
    add rsi, 32
    jmp .avx_loop

    ; --- Scalar Fallback Loop ---
.scalar_loop:
    mov r8, r15
    sub r8, r13
    inc r8              ; r8 = end limit for search
    
.scalar_next:
    cmp rsi, r8
    jge exit_flush
    mov al, [rbx + rsi]
    cmp al, [r12]
    jne .scalar_inc
    call verify_match_scalar
.scalar_inc:
    inc rsi
    jmp .scalar_next

exit_flush:
    call flush_buffer
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

; =============================================================================
; Error Handling
; =============================================================================

open_error:
    call ensure_rax_positive
    call print_err_prefix
    call print_errno_desc
    jmp exit_flush

lseek_error:
    call ensure_rax_positive
    call print_err_prefix
    call print_errno_desc
    jmp exit_flush

mmap_error:
    call ensure_rax_positive
    call print_err_prefix
    call print_errno_desc
    jmp exit_flush

ensure_rax_positive:
    test rax, rax
    jns .done
    neg rax
.done:
    ret

usage_exit:
    mov rsi, msg_usage
    mov rdx, msg_usage_len
    call write_to_buffer
    jmp exit_flush

; =============================================================================
; Helper Functions
; =============================================================================

print_err_prefix:
    mov rsi, msg_err_prefix
    mov rdx, msg_err_prefix_len
    call write_to_buffer
    ret

print_errno_desc:
    ; Input: rax (positive errno)
    cmp rax, ENOENT
    je .no_file
    cmp rax, EACCES
    je .no_perm
    cmp rax, EISDIR
    je .is_dir
    cmp rax, ENOMEM
    je .no_mem
    cmp rax, EFBIG
    je .too_big
    
    ; Unknown error
    push rax
    mov rsi, err_unknown
    call strlen_rsi
    call write_to_buffer
    pop rax
    call print_rax
    ret

.no_file:
    mov rsi, err_no_file
    jmp .print_str
.no_perm:
    mov rsi, err_no_perm
    jmp .print_str
.is_dir:
    mov rsi, err_is_dir
    jmp .print_str
.no_mem:
    mov rsi, err_no_mem
    jmp .print_str
.too_big:
    mov rsi, err_too_big
.print_str:
    call strlen_rsi
    call write_to_buffer
    mov rsi, newline
    mov rdx, 1
    call write_to_buffer
    ret

strlen_rsi:
    push rdi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rdi
    ret

print_rax:
    ; Prints unsigned integer in rax to buffer
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rdi, num_scratch + 31
    mov byte [rdi], 10      ; Null-terminator/Newline place
    mov rbx, 10
    mov rcx, 1              ; Length

.convert:
    xor rdx, rdx
    div rbx                 ; rax = rax / 10, rdx = rax % 10
    add dl, '0'
    dec rdi
    mov [rdi], dl
    inc rcx
    test rax, rax
    jnz .convert

    mov rsi, rdi
    mov rdx, rcx
    call write_to_buffer

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

flush_buffer:
    push rax
    push rdi
    push rsi
    push rdx
    mov rsi, out_buf
    mov rdx, [out_buf_ptr]
    sub rdx, rsi
    jz .done
    mov rax, SYS_WRITE
    mov rdi, 1      ; stdout
    syscall
    mov qword [out_buf_ptr], out_buf
.done:
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

write_to_buffer:
    ; Input: rsi (buffer), rdx (length)
    push rax
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx
.check_space:
    mov rbx, out_buf
    add rbx, OUT_BUF_SIZE
    mov rax, [out_buf_ptr]
    mov rcx, rax
    add rcx, rdx
    cmp rcx, rbx
    jl .copy
    
    ; Not enough space, flush first
    call flush_buffer
    
    ; If chunk is larger than buffer, write directly
    cmp rdx, OUT_BUF_SIZE
    jl .check_space
    mov rax, SYS_WRITE
    mov rdi, 1      ; stdout
    syscall
    jmp .done

.copy:
    mov rdi, rax
    mov rcx, rdx
    rep movsb
    mov [out_buf_ptr], rdi
.done:
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

process_chunk:
    ; Input: eax (bitmask of matches), rsi (current chunk offset)
    ; Purpose: Iterate through set bits in mask and verify full string match
.process_bit:
    tzcnt ecx, eax      ; Find index of first set bit
    jc .done_chunk      ; If carry set, no bits left
    
    ; Calculate potential match position
    mov rdi, rbx        ; File start
    add rdi, rsi        ; Chunk offset
    add rdi, rcx        ; Bit offset
    
    push rax
    push rsi
    push rcx
    push rdi
    
    ; Boundary check
    mov r8, rbx
    add r8, r15         ; File end
    mov r9, rdi
    add r9, r13         ; Match end
    cmp r9, r8
    jg .no_match_pop

    ; Verify full string match
    xor rax, rax
.cmp_loop:
    cmp rax, r13
    jge .match_found
    mov r8b, [r12 + rax]
    cmp r8b, [rdi + rax]
    jne .no_match_pop
    inc rax
    jmp .cmp_loop

.match_found:
    mov rdi, [rsp]      ; Restore match address
    call print_line_containing

.no_match_pop:
    pop rdi
    pop rcx
    pop rsi
    pop rax
    
    blsr eax, eax       ; Clear lowest set bit
    test eax, eax
    jnz .process_bit
.done_chunk:
    ret

verify_match_scalar:
    ; Input: rsi (offset), rbx (file start)
    push rsi
    push rdi
    push r8
    
    mov rdi, rbx
    add rdi, rsi
    
    ; Boundary check
    mov r8, rbx
    add r8, r15
    mov r9, rdi
    add r9, r13
    cmp r9, r8
    jg .scalar_nomatch
    
    xor rax, rax
.s_cmp:
    cmp rax, r13
    jge .s_match
    mov r8b, [r12 + rax]
    cmp r8b, [rdi + rax]
    jne .scalar_nomatch
    inc rax
    jmp .s_cmp

.s_match:
    call print_line_containing

.scalar_nomatch:
    pop r8
    pop rdi
    pop rsi
    ret

print_line_containing:
    ; Input: rdi (address inside line to print)
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    
    mov r8, rdi
    
    ; Scan backwards for newline or start of file
.scan_back:
    cmp r8, rbx
    jle .found_start
    cmp byte [r8 - 1], 10
    je .found_start
    dec r8
    jmp .scan_back

.found_start:
    ; Check if this line was already printed
    mov rax, [last_printed_end]
    cmp r8, rax
    jl .skip_print      ; Start is before last printed end -> Duplicate
    
    ; Scan forwards for newline or end of file
    mov r9, rdi
    mov rcx, rbx
    add rcx, r15
.scan_fwd:
    cmp r9, rcx
    jge .found_end
    cmp byte [r9], 10
    je .found_end_newline
    inc r9
    jmp .scan_fwd

.found_end_newline:
    inc r9              ; Include newline
.found_end:
    mov rsi, r8
    mov rdx, r9
    sub rdx, r8
    call write_to_buffer
    
    mov [last_printed_end], r9

.skip_print:
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    ret

strlen:
    xor rax, rax
.loop:
    cmp byte [rdi + rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    ret
