# mruby build configuration for the lazul kernel on amd64.
#
# "host" only provides mrbc, as in riscv64.rb (both build the same one).
# "amd64" is the library linked into the kernel: freestanding x86-64, no
# stdio, and the picolibc built for the kernel in the Dockerfile, compiled
# with the host gcc and the kernel's flags (see src/arch/amd64/arch.mk).
#
# Both build into $BUILD_ROOT/mruby: the Makefile passes its BUILD_ROOT to
# rake. Run by hand without it, that is build/ at the top of the tree.

build_root = ENV.fetch("BUILD_ROOT", File.expand_path("../build", __dir__))

MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gem core: "mruby-bin-mrbc"
  conf.build_dir = File.join(build_root, "mruby/host")
end

MRuby::CrossBuild.new("amd64") do |conf|
  conf.toolchain :gcc
  conf.build_dir = File.join(build_root, "mruby/amd64")

  arch_flags = %w[-mcmodel=small -mno-red-zone -fno-pic -fno-pie
    -fno-stack-protector -U_FORTIFY_SOURCE -fcf-protection=none]

  conf.cc do |cc|
    cc.command = "x86_64-linux-gnu-gcc"
    cc.flags = arch_flags + %w[--specs=/opt/picolibc-amd64/lib/picolibc.specs
      -O2 -g -ffreestanding -fno-common -ffunction-sections -fdata-sections]
    cc.defines += %w[MRB_NO_STDIO MRB_INT64 MRB_UTF8_STRING]
  end
  conf.linker.command = "x86_64-linux-gnu-gcc"
  conf.archiver.command = "x86_64-linux-gnu-ar"

  conf.disable_cxx_exception
  conf.build_mrbtest_lib_only

  conf.gembox "stdlib"
  conf.gem core: "mruby-compiler"  # lets the console REPL evaluate source
  conf.gem core: "mruby-eval"
  # Integer literals beyond 32 bits, as in riscv64.rb.
  conf.gem core: "mruby-bigint"
  conf.gem core: "mruby-error"
  conf.gem core: "mruby-sprintf"
  conf.gem core: "mruby-pack"
  conf.gem core: "mruby-struct"
  conf.gem core: "mruby-metaprog"
  conf.gem core: "mruby-method"
end
