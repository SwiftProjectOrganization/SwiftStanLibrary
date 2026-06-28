alist(
	wait ~ dnorm( mu , sigma ),
	mu <- a_cafe[cafe] + b_cafe[cafe]*afternoon,
	c(a_cafe,b_cafe)[cafe] ~ dmvnorm2(c(a,b),sigma_cafe,Rho),
	a ~ dnorm(0,10),
	b ~ dnorm(0,10),
	sigma_cafe ~ dcauchy(0,2),
	sigma ~ dcauchy(0,2),
	Rho ~ dlkjcorr(2)
)
