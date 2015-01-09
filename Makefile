REBAR?=./rebar


all: build


clean:
	$(REBAR) clean
	rm -rf logs
	rm -rf .eunit


distclean: clean
	git clean -fxd


deps:
	@if test ! -d ./deps; then \
		$(REBAR) get-deps; \
	fi


build: deps
	$(REBAR) compile


eunit:
	$(REBAR) eunit


check: build eunit


build-plt:
	dialyzer --build_plt --output_plt .ets_lru.plt \
		--apps erts kernel stdlib

dialyze:
	dialyzer --src src --plt .ets_lru.plt --no_native -Werror_handling \
	-Wrace_conditions -Wunmatched_returns

.PHONY: all clean distclean deps build eunit check
