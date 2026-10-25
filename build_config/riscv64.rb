# mruby build configuration for the lazul kernel.
#
# "host" only provides mrbc, used to compile the kernel's Ruby sources into
# bytecode at build time. "riscv64" is the library linked into the kernel:
# freestanding RV64, no stdio, picolibc as the C library.
#
# Both build into $BUILD_ROOT/mruby: the Makefile passes its BUILD_ROOT to
# rake. Run by hand without it, that is build/ at the top of the tree.

build_root = ENV.fetch("BUILD_ROOT", File.expand_path("../build", __dir__))

MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gem core: "mruby-bin-mrbc"
  conf.build_dir = File.join(build_root, "mruby/host")
end

MRuby::CrossBuild.new("riscv64") do |conf|
  conf.toolchain :gcc
  conf.build_dir = File.join(build_root, "mruby/riscv64")

  arch_flags = %w[-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany]

  conf.cc do |cc|
    cc.command = "riscv64-unknown-elf-gcc"
    cc.flags = arch_flags + %w[--specs=picolibc.specs -O2 -g -ffreestanding
                               -fno-common -ffunction-sections -fdata-sections]
    cc.defines += %w[MRB_NO_STDIO MRB_INT64 MRB_UTF8_STRING]
  end
  conf.linker.command = "riscv64-unknown-elf-gcc"
  conf.archiver.command = "riscv64-unknown-elf-ar"

  conf.disable_cxx_exception
  conf.build_mrbtest_lib_only

  conf.gembox "stdlib"
  conf.gem core: "mruby-compiler"  # lets the console REPL evaluate source
  conf.gem core: "mruby-eval"
  conf.gem core: "mruby-error"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-pack"
  conf.gem core: "mruby-struct"
  conf.gem core: "mruby-metaprog"
  conf.gem core: "mruby-method"
end
